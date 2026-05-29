import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import '../models/beacon.dart';
import '../models/beacon_placement.dart';
import '../models/fingerprint.dart';
import '../models/floor_plan.dart';
import '../models/position_estimate.dart';
import '../models/position_strategy.dart';
import 'ble_scanner.dart';
import 'storage.dart';
import 'walkable.dart';

/// Berechnet aus den live empfangenen BLE-Scans eine aktuelle
/// User-Position auf dem aktiven Stockwerk.
///
/// Pipeline:
/// ```
///   BleScanner.stream ──► RSSI-Glättung ──► Distanz pro Beacon
///                                              │
///                                              ▼
///                          Trilateration / Weighted-Centroid / Proximity
///                                              │
///                                              ▼
///                                    PositionEstimate?
/// ```
///
/// **RSSI-Glättung:** Moving-Average der letzten `smoothingWindow`
/// Messungen pro Beacon. Filtert kurzfristige Multipath-Spitzen, hält
/// die Latenz aber unter ~5 Samples (~5 s bei 1 Hz Beacon-Intervall).
///
/// **Trilateration:** lineares Least-Squares mit Referenz-Beacon-
/// Subtraktion (Foy, 1976). Schnell (<1 ms), für die Live-Update-Rate
/// ausreichend. Bei stark verrauschten Daten ist ein iteratives
/// Levenberg-Marquardt-Verfahren marginal genauer, aber 5–10× teurer
/// — der zusätzliche Gewinn würde durch das Moving-Average davor
/// ohnehin grossteils kompensiert.
class PositionEngine {
  PositionEngine({
    required BleScanner scanner,
    required Storage storage,
    this.strategy = PositionStrategy.trilateration,
    this.smoothingWindow = 5,
    this.pathLossExponent = 2.5,
    this.maxUsableDistanceMeters = 15.0,
    this.maxBeaconsForFix = 5,
    this.positionSmoothing = 0.35,
    this.knnK = 3,
    this.knnMinCommonBeacons = 2,
    this.snapToWalkableEnabled = true,
  })  : _scanner = scanner,
        _storage = storage {
    _sub = _scanner.stream.listen(_onScans);
    refreshPlacements();
    refreshFingerprints();
    refreshWalkable();
    // Auf Fingerprint-/Zonen-Änderungen reagieren (egal welche Code-Stelle
    // schreibt) — robuster als manuelle Koordination durch die Screens.
    _storage.fingerprintsRevision.addListener(refreshFingerprints);
    _storage.walkableRevision.addListener(refreshWalkable);
  }

  final BleScanner _scanner;
  final Storage _storage;

  /// Aktives Positions-Verfahren. Wird im Settings-Screen umgeschaltet und
  /// gilt ab dem nächsten Scan-Update. `late`/`final` bewusst nicht — der
  /// Wert ist zur Laufzeit veränderbar.
  PositionStrategy strategy;

  /// k für den k-Nearest-Neighbors-Abgleich (Anzahl nächster Fingerprints).
  final int knnK;

  /// Minimale Anzahl Beacons, die ein Fingerprint mit der aktuellen Signatur
  /// gemeinsam haben muss, um überhaupt verglichen zu werden.
  final int knnMinCommonBeacons;

  /// Wenn `true`, wird die berechnete Position auf die begehbare Fläche
  /// geklemmt (Snap-to-Walkable, Spec 04) — der Marker landet nie in einer
  /// Wand oder im Luftraum.
  final bool snapToWalkableEnabled;

  /// Anzahl der RSSI-Messungen im gleitenden Fenster pro Beacon.
  final int smoothingWindow;

  final double pathLossExponent;

  /// Beacons, die weiter als dieser Wert entfernt erscheinen, werden aus der
  /// Positionsberechnung ausgeschlossen. Bei grossen Distanzen ist das
  /// RSSI-Signal durch Wände und Multipath dominiert und das Pfadverlust-
  /// Modell unzuverlässig — ein ferner Beacon verschlechtert die Lösung eher,
  /// als dass er sie verbessert.
  final double maxUsableDistanceMeters;

  /// Maximale Anzahl Beacons, die in eine Positionsberechnung einfliessen.
  /// Es werden die nächsten (= stärksten, zuverlässigsten) Beacons bevorzugt.
  final int maxBeaconsForFix;

  /// Glättungsfaktor (EMA) für die finale Position, Bereich (0, 1].
  /// 1.0 = keine Glättung (Rohwert), kleinere Werte = stärkere Glättung
  /// gegen das „Springen" des Markers. 0.35 ist ein Kompromiss zwischen
  /// Reaktionsfähigkeit und Ruhe.
  final double positionSmoothing;

  /// Letzte geglättete Position (für die EMA). `null` = noch keine / Reset.
  Offset? _smoothedPos;

  final Map<int, Queue<int>> _rssiHistory = {};
  List<BeaconPlacement> _placements = const [];
  List<Fingerprint> _fingerprints = const [];
  // Begehbare Rechtecke (Zonen oder Räume) + Lufträume des aktiven Floors.
  List<Rect> _walkableRects = const [];
  List<Rect> _voidRects = const [];
  StreamSubscription<Map<String, BeaconScan>>? _sub;

  final StreamController<PositionEstimate?> _controller =
      StreamController.broadcast();
  PositionEstimate? _latest;

  Stream<PositionEstimate?> get stream => _controller.stream;
  PositionEstimate? get latest => _latest;
  List<BeaconPlacement> get placements => List.unmodifiable(_placements);

  /// Lädt die aktuelle Beacon-Konfiguration aus dem Storage neu.
  /// Vom Setup-Screen nach jeder Änderung aufrufen.
  Future<void> refreshPlacements() async {
    _placements = await _storage.loadBeaconPlacements();
    // Bei Änderungen sofort neu rechnen, falls schon Scans vorliegen.
    _onScans(_scanner.current);
  }

  /// Lädt die Fingerprints des aktiven Stockwerks neu (harter Floor-Filter,
  /// damit Fingerprints anderer Stöcke die Position nicht verfälschen).
  /// Vom CalibrationScreen nach jedem Speichern/Löschen und beim Floor-Wechsel
  /// aufrufen.
  Future<void> refreshFingerprints() async {
    final floorId = _storage.activeFloorId;
    final all = await _storage.loadFingerprints();
    _fingerprints = floorId == null
        ? all
        : all.where((f) => f.floorId == floorId).toList();
    _onScans(_scanner.current);
  }

  /// Anzahl aktuell geladener Fingerprints (für UI-Hinweise).
  int get fingerprintCount => _fingerprints.length;

  /// Lädt die begehbare Fläche des aktiven Stockwerks neu (gezeichnete Zonen,
  /// sonst die Räume als Fallback) plus die Lufträume. Aufgerufen beim
  /// Floor-Wechsel und automatisch bei Zonen-Änderungen (walkableRevision).
  Future<void> refreshWalkable() async {
    final floor = floorById(_storage.activeFloorId);
    final zones = await _storage.loadWalkableZonesForFloor(floor.id);
    _walkableRects = walkableRectsFor(floor, zones);
    _voidRects = [for (final v in floor.voids) v.bounds];
    _onScans(_scanner.current);
  }

  void _onScans(Map<String, BeaconScan> scans) {
    // 1. RSSI-Historie für jeden empfangenen Beacon aktualisieren.
    for (final s in scans.values) {
      if (s.beaconId == null) continue;
      _pushRssi(s.beaconId!, s.rssi);
    }

    // 2. Für jeden PLATZIERTEN Beacon, der gerade sichtbar ist,
    //    Distanz aus dem geglätteten RSSI berechnen.
    final readings = <BeaconDistance>[];
    for (final p in _placements) {
      final scan = _findScan(scans, p.beaconId);
      if (scan == null) continue;
      final hist = _rssiHistory[p.beaconId];
      if (hist == null || hist.isEmpty) continue;

      final tx = p.txPowerOverride ?? scan.txPower;
      if (tx == null) continue;

      // Median statt Mittelwert: robust gegen einzelne Multipath-Spikes,
      // die einen gleitenden Mittelwert verzerren würden.
      final smoothedRssi = median(hist);
      final distance = BeaconScan.distanceFromRssi(
        rssi: smoothedRssi,
        txPower: tx,
        pathLossExponent: pathLossExponent,
      );

      readings.add(BeaconDistance(p, distance));
    }

    // 3. Beacons filtern + priorisieren (Cutoff ferner Beacons, nächste N).
    final selected = selectReadings(readings);

    // 4. Position je nach gewähltem Verfahren berechnen.
    final raw = switch (strategy) {
      PositionStrategy.trilateration => solve(selected),
      PositionStrategy.fingerprinting =>
        kNNMatch(currentSmoothedRssi(scans), _fingerprints),
      PositionStrategy.hybrid => _combineHybrid(
          solve(selected),
          kNNMatch(currentSmoothedRssi(scans), _fingerprints),
        ),
    };

    // 5. Glätten (Anti-Springen), auf begehbare Fläche snappen, publizieren.
    _latest = _applySnap(_smoothPosition(raw));
    _controller.add(_latest);
  }

  /// Klemmt die Position auf die begehbare Fläche (Spec 04). No-Op, wenn
  /// deaktiviert oder kein begehbares Modell vorhanden ist.
  PositionEstimate? _applySnap(PositionEstimate? est) {
    if (est == null || !snapToWalkableEnabled || _walkableRects.isEmpty) {
      return est;
    }
    return est.copyWith(
      positionMeters: snapToWalkable(est.positionMeters, _walkableRects, _voidRects),
    );
  }

  /// Aktuelle, geglättete RSSI-Signatur: Median der RSSI-Historie je sichtbarem
  /// Beacon. Eingabe für den Fingerprint-Abgleich. Öffentlich für Unit-Tests.
  Map<int, double> currentSmoothedRssi(Map<String, BeaconScan> scans) {
    final result = <int, double>{};
    for (final s in scans.values) {
      final id = s.beaconId;
      if (id == null) continue;
      final hist = _rssiHistory[id];
      if (hist == null || hist.isEmpty) continue;
      result[id] = median(hist);
    }
    return result;
  }

  /// Filtert und priorisiert die Roh-Distanzmessungen für die Berechnung:
  /// 1. Beacons jenseits [maxUsableDistanceMeters] verwerfen (Wand/Multipath).
  /// 2. Nach Distanz aufsteigend sortieren (nächste = zuverlässigste zuerst).
  /// 3. Auf die nächsten [maxBeaconsForFix] begrenzen.
  ///
  /// Öffentlich für Unit-Tests (deterministisch, ohne BLE-Stack).
  List<BeaconDistance> selectReadings(List<BeaconDistance> readings) {
    final usable = readings
        .where((r) => r.distance <= maxUsableDistanceMeters)
        .toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));
    if (usable.length <= maxBeaconsForFix) return usable;
    return usable.sublist(0, maxBeaconsForFix);
  }

  /// Glättet die finale Position per exponentiellem gleitendem Mittel.
  /// Bei `null` (keine Position) wird der Glättungs-Zustand zurückgesetzt,
  /// damit die nächste gültige Position nicht von einer alten „nachgezogen"
  /// wird.
  PositionEstimate? _smoothPosition(PositionEstimate? raw) {
    if (raw == null) {
      _smoothedPos = null;
      return null;
    }
    final target = raw.positionMeters;
    final prev = _smoothedPos;
    final next = prev == null
        ? target
        : Offset(
            positionSmoothing * target.dx + (1 - positionSmoothing) * prev.dx,
            positionSmoothing * target.dy + (1 - positionSmoothing) * prev.dy,
          );
    _smoothedPos = next;
    return raw.copyWith(positionMeters: next);
  }

  // --- Numerik (öffentlich exposed für Unit-Tests) -----------------------

  /// Hauptlöser: wählt das passende Verfahren nach Anzahl der Beacons.
  /// Statisch nutzbar — bekommt fertige `(placement, distance)`-Paare.
  PositionEstimate? solve(List<BeaconDistance> readings) {
    if (readings.isEmpty) return null;
    final ts = DateTime.now();

    if (readings.length == 1) {
      final b = readings.first;
      return PositionEstimate(
        positionMeters: Offset(b.placement.xMeters, b.placement.yMeters),
        confidence: 0.20,
        beaconsUsed: 1,
        method: PositionMethod.proximity,
        timestamp: ts,
      );
    }

    if (readings.length == 2) {
      // Distanz-gewichtetes Mittel: näher = mehr Einfluss.
      var sumWX = 0.0;
      var sumWY = 0.0;
      var sumW = 0.0;
      for (final r in readings) {
        final w = 1.0 / math.max(r.distance, 0.5);
        sumWX += r.placement.xMeters * w;
        sumWY += r.placement.yMeters * w;
        sumW += w;
      }
      return PositionEstimate(
        positionMeters: Offset(sumWX / sumW, sumWY / sumW),
        confidence: 0.50,
        beaconsUsed: 2,
        method: PositionMethod.weightedCentroid,
        timestamp: ts,
      );
    }

    return _trilaterate(readings, ts);
  }

  PositionEstimate? _trilaterate(
    List<BeaconDistance> readings,
    DateTime ts,
  ) {
    // Referenz-Subtraktion (Foy 1976):
    // (x - xᵢ)² + (y - yᵢ)² = dᵢ²
    // Subtrahiere Gleichung 1 von Gleichung i:
    //   2x(xᵢ - x₁) + 2y(yᵢ - y₁) = (xᵢ²-x₁²) + (yᵢ²-y₁²) - (dᵢ² - d₁²)
    // → lineares System  A · [x, y]ᵀ = b
    final x1 = readings[0].placement.xMeters;
    final y1 = readings[0].placement.yMeters;
    final d1sq = readings[0].distance * readings[0].distance;

    final n = readings.length - 1;
    final aRows = List<List<double>>.generate(n, (_) => [0.0, 0.0]);
    final b = List<double>.filled(n, 0.0);

    for (var i = 1; i < readings.length; i++) {
      final xi = readings[i].placement.xMeters;
      final yi = readings[i].placement.yMeters;
      final disq = readings[i].distance * readings[i].distance;
      aRows[i - 1][0] = 2 * (xi - x1);
      aRows[i - 1][1] = 2 * (yi - y1);
      b[i - 1] =
          (xi * xi - x1 * x1) + (yi * yi - y1 * y1) - (disq - d1sq);
    }

    // Normalengleichung AᵀA · x̂ = Aᵀb → 2×2-System, Cramer-Regel
    var a11 = 0.0, a12 = 0.0, a22 = 0.0;
    var bv1 = 0.0, bv2 = 0.0;
    for (var i = 0; i < n; i++) {
      a11 += aRows[i][0] * aRows[i][0];
      a12 += aRows[i][0] * aRows[i][1];
      a22 += aRows[i][1] * aRows[i][1];
      bv1 += aRows[i][0] * b[i];
      bv2 += aRows[i][1] * b[i];
    }

    final det = a11 * a22 - a12 * a12;
    if (det.abs() < 1e-9) {
      // Degenerierte Geometrie (z. B. alle Beacons kollinear).
      return null;
    }

    final x = (a22 * bv1 - a12 * bv2) / det;
    final y = (a11 * bv2 - a12 * bv1) / det;
    final pos = Offset(x, y);

    // Residuum: wie gut passen die geschätzten Distanzen zu den
    // gemessenen? RMSE über alle Beacons.
    var sqSum = 0.0;
    for (final r in readings) {
      final estimated = (pos -
              Offset(r.placement.xMeters, r.placement.yMeters))
          .distance;
      sqSum += math.pow(estimated - r.distance, 2);
    }
    final rmse = math.sqrt(sqSum / readings.length);

    // Confidence: Mapping 0 m RMSE → 1.0, 5 m → 0.0
    final confidence = (1.0 - rmse / 5.0).clamp(0.0, 1.0);

    return PositionEstimate(
      positionMeters: pos,
      confidence: confidence,
      beaconsUsed: readings.length,
      method: PositionMethod.trilateration,
      residualMeters: rmse,
      timestamp: ts,
    );
  }

  // --- Fingerprinting (k-Nearest-Neighbors) -----------------------------

  /// Bestimmt die Position per **k-Nearest-Neighbors** aus der aktuellen
  /// RSSI-Signatur und einer Fingerprint-Datenbank (Spec 01).
  ///
  /// Distanz im Signalraum: **RMS** der RSSI-Differenzen über die gemeinsamen
  /// Beacons — `sqrt(Σ(Δrssi)² / gemeinsame)`. Die Normierung auf die Anzahl
  /// gemeinsamer Beacons (statt der reinen Euklid-Summe) hält Fingerprints mit
  /// unterschiedlich vielen Überschneidungen vergleichbar und macht die
  /// dB-basierte Confidence-Abbildung sinnvoll.
  ///
  /// Ausgabe-Position = mit `1/Distanz` gewichtetes Mittel der `k` nächsten
  /// Fingerprints (näher = mehr Einfluss). Öffentlich für Unit-Tests.
  PositionEstimate? kNNMatch(
    Map<int, double> currentRssi,
    List<Fingerprint> fingerprints, {
    int? k,
    int? minCommonBeacons,
    DateTime? timestamp,
  }) {
    if (currentRssi.isEmpty || fingerprints.isEmpty) return null;
    final kk = k ?? knnK;
    final minCommon = minCommonBeacons ?? knnMinCommonBeacons;

    final scored = <_FpScore>[];
    for (final fp in fingerprints) {
      var sumSq = 0.0;
      var common = 0;
      for (final entry in currentRssi.entries) {
        final ref = fp.rssiByBeaconId[entry.key];
        if (ref == null) continue;
        final diff = entry.value - ref;
        sumSq += diff * diff;
        common++;
      }
      if (common < minCommon) continue;
      scored.add(_FpScore(fp, math.sqrt(sumSq / common), common));
    }
    if (scored.isEmpty) return null;

    scored.sort((a, b) => a.distance.compareTo(b.distance));
    final top = scored.take(kk).toList();

    var sumWX = 0.0, sumWY = 0.0, sumW = 0.0, sumDist = 0.0;
    for (final s in top) {
      // 1/Distanz-Gewicht; clamp gegen Division durch 0 bei exaktem Treffer.
      final w = 1.0 / math.max(s.distance, 1e-6);
      sumWX += s.fp.xMeters * w;
      sumWY += s.fp.yMeters * w;
      sumW += w;
      sumDist += s.distance;
    }
    final pos = Offset(sumWX / sumW, sumWY / sumW);
    final meanDist = sumDist / top.length;
    // 0 dB Abweichung → Confidence 1.0; 30 dB → 0.0.
    final confidence = (1.0 - meanDist / 30.0).clamp(0.0, 1.0);

    return PositionEstimate(
      positionMeters: pos,
      confidence: confidence,
      beaconsUsed: top.first.commonBeacons,
      method: PositionMethod.fingerprinting,
      residualMeters: meanDist,
      timestamp: timestamp ?? DateTime.now(),
    );
  }

  /// Kombiniert Trilaterations- und Fingerprint-Schätzung für den Hybrid-Modus.
  /// Fällt auf das vorhandene Verfahren zurück, wenn eines `null` liefert;
  /// sonst Position = nach Confidence gewichtetes Mittel beider Schätzungen.
  PositionEstimate? _combineHybrid(
    PositionEstimate? tri,
    PositionEstimate? fp,
  ) {
    if (tri == null) return fp;
    if (fp == null) return tri;

    final wt = tri.confidence;
    final wf = fp.confidence;
    final sum = wt + wf;
    final pos = sum <= 0
        ? Offset(
            (tri.positionMeters.dx + fp.positionMeters.dx) / 2,
            (tri.positionMeters.dy + fp.positionMeters.dy) / 2,
          )
        : Offset(
            (tri.positionMeters.dx * wt + fp.positionMeters.dx * wf) / sum,
            (tri.positionMeters.dy * wt + fp.positionMeters.dy * wf) / sum,
          );

    return PositionEstimate(
      positionMeters: pos,
      confidence: math.max(tri.confidence, fp.confidence),
      beaconsUsed: math.max(tri.beaconsUsed, fp.beaconsUsed),
      method: PositionMethod.hybrid,
      residualMeters: tri.residualMeters ?? fp.residualMeters,
      timestamp: tri.timestamp,
    );
  }

  // --- Helpers ----------------------------------------------------------

  void _pushRssi(int id, int rssi) {
    final q = _rssiHistory.putIfAbsent(id, Queue<int>.new);
    q.addLast(rssi);
    while (q.length > smoothingWindow) {
      q.removeFirst();
    }
  }

  /// Median der RSSI-Historie. Robuster gegen Ausreisser (Multipath-Spikes)
  /// als der arithmetische Mittelwert: ein einzelner Spike verschiebt den
  /// Median nicht. Öffentlich für Unit-Tests.
  double median(Iterable<int> values) {
    final list = values.toList()..sort();
    if (list.isEmpty) return 0;
    final mid = list.length ~/ 2;
    if (list.length.isOdd) return list[mid].toDouble();
    return (list[mid - 1] + list[mid]) / 2.0;
  }

  BeaconScan? _findScan(Map<String, BeaconScan> scans, int beaconId) {
    for (final s in scans.values) {
      if (s.beaconId == beaconId) return s;
    }
    return null;
  }

  Future<void> dispose() async {
    _storage.fingerprintsRevision.removeListener(refreshFingerprints);
    _storage.walkableRevision.removeListener(refreshWalkable);
    await _sub?.cancel();
    await _controller.close();
  }
}

/// Eingangspaar für den Trilateration-Löser: ein platzierter Beacon mit
/// der aktuell gemessenen Distanz in Metern.
///
/// Wird intern aus dem RSSI-Glätter gefüllt; in Unit-Tests direkt
/// konstruierbar, um den Solver ohne BLE-Stack zu prüfen.
class BeaconDistance {
  const BeaconDistance(this.placement, this.distance);
  final BeaconPlacement placement;
  final double distance;
}

/// Intern: ein Fingerprint mit seiner RMS-Distanz zur aktuellen Signatur
/// und der Anzahl gemeinsamer Beacons (für die kNN-Sortierung).
class _FpScore {
  const _FpScore(this.fp, this.distance, this.commonBeacons);
  final Fingerprint fp;
  final double distance;
  final int commonBeacons;
}
