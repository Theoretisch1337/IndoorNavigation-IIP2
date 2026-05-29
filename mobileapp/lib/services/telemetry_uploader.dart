import 'dart:async';

import '../models/beacon.dart';
import '../models/telemetry_record.dart';
import 'api_service.dart';

/// Momentaufnahme des Upload-Zustands für die UI-Anzeige.
class TelemetryStats {
  final int queued;
  final int totalSent;
  final int totalFailed;
  final DateTime? lastFlush;
  final bool lastFlushOk;
  final String? lastError;

  const TelemetryStats({
    required this.queued,
    required this.totalSent,
    required this.totalFailed,
    this.lastFlush,
    this.lastFlushOk = false,
    this.lastError,
  });

  /// `true`, wenn der letzte Upload erfolgreich war (C2 erreichbar).
  bool get c2Reachable => lastFlush != null && lastFlushOk;
}

/// Sammelt Beacon-Telemetrie und lädt sie gebündelt zum C2-Server hoch.
///
/// Strategie:
/// - Eingehende Scans werden pro (Beacon, Sequenz) dedupliziert (Map-Key).
/// - Alle [flushInterval] Sekunden wird die Queue als Batch hochgeladen.
/// - Bei Upload-Fehler bleiben die Records in der Queue (Retry beim nächsten
///   Flush) — die App ist damit offline-tolerant.
/// - Bei voller Queue ([maxQueueSize]) werden die ältesten Records verworfen,
///   damit der Speicher nicht unbegrenzt wächst wenn C2 lange offline ist.
///
/// Der [stats]-Stream erlaubt der UI, den Upload-Zustand live anzuzeigen
/// (queued / gesendet / C2 erreichbar) — wichtig für den "vollen Überblick"
/// auch ohne C2-Dashboard.
class TelemetryUploader {
  TelemetryUploader({
    required this.api,
    required this.deviceId,
    this.flushInterval = const Duration(seconds: 30),
    this.maxQueueSize = 500,
  });

  final ApiService api;
  final String deviceId;
  final Duration flushInterval;
  final int maxQueueSize;

  // dedupeKey ("beaconId:sequence") → Record. LinkedHashMap-Semantik:
  // Einfüge-Reihenfolge bleibt erhalten, sodass "ältester" = erster Key.
  final Map<String, TelemetryRecord> _queue = {};
  Timer? _timer;
  bool _flushing = false;

  int _totalSent = 0;
  int _totalFailed = 0;
  DateTime? _lastFlush;
  bool _lastFlushOk = false;
  String? _lastError;

  final StreamController<TelemetryStats> _statsController =
      StreamController<TelemetryStats>.broadcast();

  Stream<TelemetryStats> get stats => _statsController.stream;

  TelemetryStats get currentStats => TelemetryStats(
        queued: _queue.length,
        totalSent: _totalSent,
        totalFailed: _totalFailed,
        lastFlush: _lastFlush,
        lastFlushOk: _lastFlushOk,
        lastError: _lastError,
      );

  /// Startet den periodischen Upload-Timer.
  void start() {
    _timer ??= Timer.periodic(flushInterval, (_) => flush());
  }

  /// Stoppt den Timer und versucht einen letzten Flush.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await flush();
  }

  /// Reiht die Telemetrie eines Scans ein. Nur eigene Beacons
  /// (`beaconId != null`) werden aufgenommen.
  void enqueueScan(BeaconScan scan) {
    if (scan.beaconId == null) return;
    final record = TelemetryRecord.fromScan(scan, deviceId);
    _queue[record.dedupeKey] = record;

    // Queue-Cap: bei Überlauf die ältesten Records verwerfen
    while (_queue.length > maxQueueSize) {
      _queue.remove(_queue.keys.first);
    }
    _emitStats();
  }

  /// Lädt die aktuelle Queue als Batch hoch. Bei Erfolg werden die
  /// gesendeten Records entfernt; bei Fehler bleiben sie für den Retry.
  Future<void> flush() async {
    if (_flushing || _queue.isEmpty) return;
    _flushing = true;

    final batch = _queue.values.toList(growable: false);
    final ok = await api.postTelemetryBatch(batch);

    _lastFlush = DateTime.now();
    _lastFlushOk = ok;
    if (ok) {
      _totalSent += batch.length;
      for (final r in batch) {
        // Nur entfernen, wenn der gespeicherte Record noch exakt der gesendete
        // ist. Zwischen dem Snapshot (oben) und hier kann der Upload bis zu
        // mehreren Sekunden gedauert haben; in dieser Zeit könnte enqueueScan
        // einen NEUEREN Record mit gleichem dedupeKey eingefügt haben (z.B.
        // bei Beacons ohne Sequenznummer, deren Key konstant bleibt). Ohne
        // den identical-Check würde dieser neuere Record ungesendet verworfen.
        if (identical(_queue[r.dedupeKey], r)) {
          _queue.remove(r.dedupeKey);
        }
      }
      _lastError = null;
    } else {
      _totalFailed += 1;
      _lastError = 'C2 nicht erreichbar';
    }

    _flushing = false;
    _emitStats();
  }

  void _emitStats() {
    if (!_statsController.isClosed) {
      _statsController.add(currentStats);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _statsController.close();
  }
}
