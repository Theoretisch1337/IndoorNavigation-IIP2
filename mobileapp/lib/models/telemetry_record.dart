import 'beacon.dart';

/// Ein Telemetrie-Datensatz für den C2-Server.
///
/// Wird aus einem [BeaconScan] erzeugt und an den C2-Server gesendet
/// (siehe `services/telemetry_uploader.dart`). Bündelt die Live-Messung
/// eines Beacons: Signalstärke, Akkustand, Sequenznummer und Zeitstempel.
///
/// Hinweis zu `batteryPercent`: bis zum Hardware-Fix aus ADR-007 (externer
/// Spannungsteiler am ESP32 C6) liefert die Firmware hier 0. Die Pipeline
/// ist dennoch vollständig — sobald der Spannungsteiler verbaut ist, fliessen
/// echte Werte ohne Code-Änderung.
class TelemetryRecord {
  final int beaconId;
  final String deviceId;
  final int rssi;
  final int? batteryPercent;
  final int? sequence;
  final DateTime timestamp;

  const TelemetryRecord({
    required this.beaconId,
    required this.deviceId,
    required this.rssi,
    this.batteryPercent,
    this.sequence,
    required this.timestamp,
  });

  /// Erzeugt einen Record aus einem Scan. Voraussetzung: `scan.beaconId`
  /// ist nicht null (nur eigene Beacons werden telemetriert).
  factory TelemetryRecord.fromScan(BeaconScan scan, String deviceId) {
    return TelemetryRecord(
      beaconId: scan.beaconId!,
      deviceId: deviceId,
      rssi: scan.rssi,
      batteryPercent: scan.batteryPercent,
      sequence: scan.sequenceNum,
      timestamp: scan.lastSeen,
    );
  }

  /// Dedup-Schlüssel: pro (Beacon, Sequenznummer) genau ein Record.
  /// Verhindert, dass die Upload-Queue mit Duplikaten flutet, wenn der
  /// BLE-Stack dasselbe Advertisement mehrfach liefert.
  String get dedupeKey => '$beaconId:$sequence';

  Map<String, dynamic> toJson() => {
        'beaconId': beaconId,
        'deviceId': deviceId,
        'rssi': rssi,
        if (batteryPercent != null) 'batteryPercent': batteryPercent,
        if (sequence != null) 'sequence': sequence,
        'ts': timestamp.toUtc().toIso8601String(),
      };

  factory TelemetryRecord.fromJson(Map<String, dynamic> json) {
    return TelemetryRecord(
      beaconId: json['beaconId'] as int,
      deviceId: json['deviceId'] as String,
      rssi: json['rssi'] as int,
      batteryPercent: json['batteryPercent'] as int?,
      sequence: json['sequence'] as int?,
      timestamp: DateTime.parse(json['ts'] as String),
    );
  }
}
