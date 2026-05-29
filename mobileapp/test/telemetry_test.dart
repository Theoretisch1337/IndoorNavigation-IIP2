import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:indoor_nav/models/beacon.dart';
import 'package:indoor_nav/models/telemetry_record.dart';
import 'package:indoor_nav/services/api_service.dart';
import 'package:indoor_nav/services/telemetry_uploader.dart';

BeaconScan _scan({
  required String deviceId,
  int? beaconId,
  int rssi = -60,
  int? battery = 82,
  int? seq = 1,
}) {
  return BeaconScan(
    deviceId: deviceId,
    name: 'InNav Beacon #$beaconId',
    rssi: rssi,
    beaconId: beaconId,
    batteryPercent: battery,
    sequenceNum: seq,
    txPower: -59,
    lastSeen: DateTime.utc(2026, 5, 29, 12, 0, 0),
  );
}

ApiService _api({required bool succeed}) {
  final client = MockClient((req) async {
    return http.Response(succeed ? '{}' : 'err', succeed ? 200 : 500);
  });
  return ApiService(client: client);
}

void main() {
  group('TelemetryRecord', () {
    test('fromScan extrahiert alle Felder', () {
      final r = TelemetryRecord.fromScan(
        _scan(deviceId: 'd1', beaconId: 3, rssi: -55, battery: 90, seq: 42),
        'app-abc',
      );
      expect(r.beaconId, 3);
      expect(r.deviceId, 'app-abc');
      expect(r.rssi, -55);
      expect(r.batteryPercent, 90);
      expect(r.sequence, 42);
    });

    test('dedupeKey = beaconId:sequence', () {
      final r = TelemetryRecord.fromScan(
        _scan(deviceId: 'd1', beaconId: 7, seq: 12),
        'app',
      );
      expect(r.dedupeKey, '7:12');
    });

    test('toJson/fromJson roundtrip', () {
      final original = TelemetryRecord.fromScan(
        _scan(deviceId: 'd1', beaconId: 2, rssi: -70, battery: 50, seq: 5),
        'app-x',
      );
      final restored = TelemetryRecord.fromJson(original.toJson());
      expect(restored.beaconId, original.beaconId);
      expect(restored.rssi, original.rssi);
      expect(restored.batteryPercent, original.batteryPercent);
      expect(restored.sequence, original.sequence);
      expect(restored.timestamp, original.timestamp);
    });
  });

  group('TelemetryUploader', () {
    test('enqueueScan ignoriert fremde Beacons (beaconId null)', () {
      final uploader = TelemetryUploader(
        api: _api(succeed: true),
        deviceId: 'app',
      );
      uploader.enqueueScan(_scan(deviceId: 'fremd', beaconId: null));
      expect(uploader.currentStats.queued, 0);
    });

    test('dedup: gleicher (beacon, seq) ergibt nur 1 Record', () {
      final uploader = TelemetryUploader(
        api: _api(succeed: true),
        deviceId: 'app',
      );
      uploader.enqueueScan(_scan(deviceId: 'd', beaconId: 1, seq: 5));
      uploader.enqueueScan(_scan(deviceId: 'd', beaconId: 1, seq: 5));
      uploader.enqueueScan(_scan(deviceId: 'd', beaconId: 1, seq: 6));
      expect(uploader.currentStats.queued, 2);
    });

    test('flush bei Erfolg leert Queue + zählt gesendet', () async {
      final uploader = TelemetryUploader(
        api: _api(succeed: true),
        deviceId: 'app',
      );
      uploader.enqueueScan(_scan(deviceId: 'd', beaconId: 1, seq: 1));
      uploader.enqueueScan(_scan(deviceId: 'd', beaconId: 2, seq: 1));
      await uploader.flush();
      expect(uploader.currentStats.queued, 0);
      expect(uploader.currentStats.totalSent, 2);
      expect(uploader.currentStats.c2Reachable, isTrue);
    });

    test('flush bei Fehler behält Queue + markiert nicht erreichbar', () async {
      final uploader = TelemetryUploader(
        api: _api(succeed: false),
        deviceId: 'app',
      );
      uploader.enqueueScan(_scan(deviceId: 'd', beaconId: 1, seq: 1));
      await uploader.flush();
      expect(uploader.currentStats.queued, 1);
      expect(uploader.currentStats.totalSent, 0);
      expect(uploader.currentStats.c2Reachable, isFalse);
      expect(uploader.currentStats.lastError, isNotNull);
    });

    test('queue-cap verwirft älteste Records bei Überlauf', () {
      final uploader = TelemetryUploader(
        api: _api(succeed: true),
        deviceId: 'app',
        maxQueueSize: 3,
      );
      // 5 verschiedene Sequenzen → nur die letzten 3 bleiben
      for (var seq = 1; seq <= 5; seq++) {
        uploader.enqueueScan(_scan(deviceId: 'd', beaconId: 1, seq: seq));
      }
      expect(uploader.currentStats.queued, 3);
    });

    test('leerer flush ist no-op (kein Crash)', () async {
      final uploader = TelemetryUploader(
        api: _api(succeed: true),
        deviceId: 'app',
      );
      await uploader.flush();
      expect(uploader.currentStats.totalSent, 0);
    });
  });
}
