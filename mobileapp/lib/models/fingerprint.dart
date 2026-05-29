import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;

/// Ein **RSSI-Fingerprint**: die gemittelte Signal-Signatur aller an einer
/// bekannten Position sichtbaren Beacons.
///
/// Kern der Fingerprinting-Lokalisierung (Spec 01): statt RSSI → Distanz →
/// Position zu rechnen (Trilateration), wird die Position direkt aus dem
/// Vergleich der aktuellen Signatur mit einer Datenbank vorab erfasster
/// Fingerprints bestimmt (k-Nearest-Neighbors).
@immutable
class Fingerprint {
  const Fingerprint({
    required this.id,
    required this.floorId,
    required this.xMeters,
    required this.yMeters,
    required this.rssiByBeaconId,
    required this.sampleCount,
    required this.capturedAt,
  });

  final String id;
  final String floorId;
  final double xMeters;
  final double yMeters;

  /// Gemittelter RSSI (dBm, negativ) je Beacon-ID über die Capture-Dauer.
  final Map<int, double> rssiByBeaconId;

  /// Gesamtzahl der RSSI-Messungen, die in diesen Fingerprint geflossen sind
  /// (über alle Beacons summiert) — Qualitätsindikator.
  final int sampleCount;

  final DateTime capturedAt;

  Offset get positionMeters => Offset(xMeters, yMeters);

  Map<String, dynamic> toJson() => {
        'id': id,
        'floorId': floorId,
        'x': xMeters,
        'y': yMeters,
        // JSON-Objekt-Keys sind immer Strings → Beacon-IDs als String
        // serialisieren, beim Laden zurück zu int parsen.
        'rssi': rssiByBeaconId.map((k, v) => MapEntry('$k', v)),
        'samples': sampleCount,
        'capturedAt': capturedAt.toIso8601String(),
      };

  factory Fingerprint.fromJson(Map<String, dynamic> json) {
    final rssiRaw = (json['rssi'] as Map<String, dynamic>? ?? const {});
    return Fingerprint(
      id: json['id'] as String,
      floorId: json['floorId'] as String,
      xMeters: (json['x'] as num).toDouble(),
      yMeters: (json['y'] as num).toDouble(),
      rssiByBeaconId: {
        for (final e in rssiRaw.entries)
          int.parse(e.key): (e.value as num).toDouble(),
      },
      sampleCount: (json['samples'] as num?)?.toInt() ?? 0,
      capturedAt:
          DateTime.tryParse(json['capturedAt'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  String toString() =>
      'Fingerprint($id @ (${xMeters.toStringAsFixed(1)}, '
      '${yMeters.toStringAsFixed(1)})m on $floorId, '
      '${rssiByBeaconId.length} beacons, $sampleCount samples)';
}

/// Sammelt während der Kalibrierung RSSI-Messungen pro Beacon und baut daraus
/// einen gemittelten [Fingerprint].
///
/// Bewusst frei von Flutter-/BLE-Abhängigkeiten → als reine Logik unit-testbar
/// (Spec 01, Test-Gruppe „Capture"). Der CalibrationScreen füttert jeden
/// eingehenden Scan via [addSample] ein und ruft am Ende [build] auf.
class FingerprintAccumulator {
  final Map<int, List<int>> _samplesByBeacon = {};

  /// Fügt eine RSSI-Messung für einen Beacon hinzu.
  void addSample(int beaconId, int rssi) {
    _samplesByBeacon.putIfAbsent(beaconId, () => <int>[]).add(rssi);
  }

  /// Wie viele Beacons aktuell mindestens eine Messung haben.
  int get beaconCount => _samplesByBeacon.length;

  /// Gesamtzahl aller Messungen über alle Beacons.
  int get totalSamples =>
      _samplesByBeacon.values.fold(0, (sum, list) => sum + list.length);

  /// Aktuelle Messungs-Anzahl je Beacon (für die Live-Anzeige im Capture-Modal).
  Map<int, int> get sampleCounts =>
      {for (final e in _samplesByBeacon.entries) e.key: e.value.length};

  /// Aktueller Median-RSSI je Beacon (für die Live-Anzeige). **Median statt
  /// Mittelwert** → robust gegen einzelne Multipath-Spitzen: ein Ausreisser
  /// (z. B. kurz −40 dBm statt der üblichen −70) verschiebt den mittleren Wert
  /// nicht.
  Map<int, double> get currentAverages => {
        for (final e in _samplesByBeacon.entries)
          if (e.value.isNotEmpty) e.key: _median(e.value),
      };

  /// Baut den Fingerprint aus den gesammelten Messungen.
  ///
  /// - Beacons mit weniger als [minSamples] Messungen werden verworfen
  ///   (zu unzuverlässig — könnten Streureflexionen sein).
  /// - Bleiben weniger als [minBeacons] übrig, ist die Position nicht
  ///   eindeutig genug → `null` (Capture verwerfen).
  Fingerprint? build({
    required String id,
    required String floorId,
    required double xMeters,
    required double yMeters,
    required DateTime capturedAt,
    int minSamples = 3,
    int minBeacons = 2,
  }) {
    final averaged = <int, double>{};
    var usedSamples = 0;
    for (final e in _samplesByBeacon.entries) {
      if (e.value.length < minSamples) continue;
      averaged[e.key] = _median(e.value);
      usedSamples += e.value.length;
    }
    if (averaged.length < minBeacons) return null;

    return Fingerprint(
      id: id,
      floorId: floorId,
      xMeters: xMeters,
      yMeters: yMeters,
      rssiByBeaconId: averaged,
      sampleCount: usedSamples,
      capturedAt: capturedAt,
    );
  }

  /// Median (robust gegen Ausreisser). Bei gerader Anzahl der Mittelwert der
  /// zwei mittleren Werte. Dasselbe Mass wie die RSSI-Glättung der
  /// PositionEngine — so verwenden Aufnahme und Live-Matching dieselbe Statistik.
  static double _median(List<int> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid].toDouble();
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }
}
