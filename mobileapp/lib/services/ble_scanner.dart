import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/beacon.dart';

/// Zentraler BLE-Scanner-Service.
///
/// Wrapper um `flutter_blue_plus`. Parst iBeacon-Advertisements und filtert
/// auf die eigene Beacon-UUID. Publiziert die aktuelle Beacon-Liste als
/// Broadcast-Stream, sodass mehrere Screens (Scan, Map, Setup) parallel
/// reagieren können.
///
/// Typischer Lifecycle:
/// 1. `await scanner.start()` — Scan aktivieren
/// 2. `scanner.stream.listen(...)` — Updates konsumieren
/// 3. `await scanner.stop()` — Scan stoppen
class BleScanner {
  BleScanner({this.targetUuid = _defaultUuid});

  /// UUID muss mit `firmware/include/config.h` → `BEACON_UUID` übereinstimmen.
  static const String _defaultUuid =
      '550e8400-e29b-41d4-a716-446655440000';

  final String targetUuid;

  /// Beacons, die länger als das nicht mehr empfangen wurden, gelten als „weg"
  /// und werden aus der Liste entfernt (relevant für den kontinuierlichen Scan).
  static const Duration _staleAfter = Duration(seconds: 15);

  final Map<String, BeaconScan> _beacons = {};
  final StreamController<Map<String, BeaconScan>> _controller =
      StreamController.broadcast();
  StreamSubscription<List<ScanResult>>? _resultsSub;
  bool _scanning = false;

  /// Broadcast-Stream der aktuellen Beacon-Liste, indiziert nach Device-ID.
  Stream<Map<String, BeaconScan>> get stream => _controller.stream;

  /// Letzter bekannter Snapshot (read-only).
  Map<String, BeaconScan> get current => Map.unmodifiable(_beacons);

  bool get isScanning => _scanning;

  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  /// Startet den BLE-Scan. Wirft `BluetoothOffException`, wenn der
  /// Adapter aus ist.
  ///
  /// `timeout == null` (Default) → **kontinuierlicher** Scan bis [stop].
  /// Die App scannt ab Start dauerhaft im Hintergrund, damit die Position
  /// sofort verfügbar ist (kein manuelles „Scan"-Tippen nötig).
  Future<void> start({Duration? timeout}) async {
    if (_scanning) return;
    if (!await isBluetoothOn()) {
      throw const BluetoothOffException();
    }

    _beacons.clear();
    _scanning = true;
    _controller.add(Map.unmodifiable(_beacons));

    _resultsSub = FlutterBluePlus.onScanResults.listen((results) {
      var changed = false;
      for (final r in results) {
        if (_processResult(r)) changed = true;
      }
      // Beim Dauer-Scan nicht mehr empfangene Beacons aussortieren, damit sie
      // nicht mit veraltetem RSSI in die Position weiterrechnen (Review-Fix).
      if (_pruneStale()) changed = true;
      if (changed) _controller.add(Map.unmodifiable(_beacons));
    });

    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidUsesFineLocation: true,
    );
  }

  Future<void> stop() async {
    if (!_scanning) return;
    await FlutterBluePlus.stopScan();
    await _resultsSub?.cancel();
    _resultsSub = null;
    _scanning = false;
    _controller.add(Map.unmodifiable(_beacons));
  }

  /// Verarbeitet ein einzelnes Scan-Result.
  /// Gibt `true` zurück, wenn die interne Beacon-Map verändert wurde.
  bool _processResult(ScanResult result) {
    final advData = result.advertisementData;
    final manufacturerData = advData.manufacturerData;

    // iBeacon-Payload aus einem der Manufacturer-Data-Einträge parsen.
    ({int beaconId, int batteryPercent, int sequenceNum, int txPower})? payload;
    for (final data in manufacturerData.values) {
      payload = parseIBeacon(data, targetUuid);
      if (payload != null) break;
    }
    final isOurs = payload != null;

    // Komplett anonyme Geräte (kein Name, keine Manufacturer-Data) ausblenden,
    // sonst füllt sich die Liste mit Audio-Geräten, Watches etc.
    if (!isOurs && advData.advName.isEmpty && manufacturerData.isEmpty) {
      return false;
    }

    final scan = BeaconScan(
      deviceId: result.device.remoteId.str,
      name: isOurs
          ? 'InNav Beacon #${payload.beaconId}'
          : (advData.advName.isNotEmpty
              ? advData.advName
              : result.device.remoteId.str),
      rssi: result.rssi,
      beaconId: payload?.beaconId,
      batteryPercent: payload?.batteryPercent,
      sequenceNum: payload?.sequenceNum,
      txPower: payload?.txPower,
      lastSeen: DateTime.now(),
    );

    _beacons[scan.deviceId] = scan;
    return true;
  }

  /// Parst eine iBeacon-Manufacturer-Data-Bytefolge und gibt die InNav-Felder
  /// zurück, oder `null` wenn es kein passender iBeacon ist (zu kurz, falscher
  /// Prefix oder fremde UUID). Pure + statisch → ohne BLE-Stack unit-testbar.
  static ({int beaconId, int batteryPercent, int sequenceNum, int txPower})?
      parseIBeacon(List<int> data, String targetUuid) {
    // [type(0x02), len(0x15), uuid(16), major(2), minor(2), txpower(1)] = 23 B
    if (data.length < 23) return null;
    if (data[0] != 0x02 || data[1] != 0x15) return null;
    final uuid = _bytesToUuid(data.sublist(2, 18));
    if (uuid.toLowerCase() != targetUuid.toLowerCase()) return null;
    final raw = data[22];
    return (
      beaconId: (data[18] << 8) | data[19],
      batteryPercent: data[20], // Minor-High
      sequenceNum: data[21], // Minor-Low
      txPower: raw > 127 ? raw - 256 : raw, // int8 sign-extension
    );
  }

  static String _bytesToUuid(List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Entfernt Beacons, die seit [_staleAfter] nicht mehr empfangen wurden.
  /// Gibt `true` zurück, wenn dadurch etwas entfernt wurde.
  bool _pruneStale() {
    final cutoff = DateTime.now().subtract(_staleAfter);
    final before = _beacons.length;
    _beacons.removeWhere((_, s) => s.lastSeen.isBefore(cutoff));
    return _beacons.length != before;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

/// Wird geworfen, wenn der BLE-Adapter beim Start eines Scans aus ist.
class BluetoothOffException implements Exception {
  const BluetoothOffException();

  @override
  String toString() => 'Bluetooth ist ausgeschaltet';
}
