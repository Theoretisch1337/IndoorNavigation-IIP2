import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav/services/ble_scanner.dart';

/// Tests für das reine iBeacon-Byte-Parsing (ohne BLE-Stack).
/// Sperrt die Payload-Interpretation fest — ein falscher Byte-Offset oder ein
/// Fehler in der UUID-Erkennung würde sonst erst im Feld auffallen.
void main() {
  const uuid = '550e8400-e29b-41d4-a716-446655440000';
  final uuidBytes = <int>[
    0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, //
    0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
  ];

  // Baut eine 23-Byte iBeacon-Payload (Manufacturer-Data-Inhalt).
  List<int> payload({
    int major = 11,
    int battery = 100,
    int seq = 42,
    int txByte = 0xC5, // -59 als int8
  }) =>
      [
        0x02, 0x15, // iBeacon-Prefix
        ...uuidBytes,
        (major >> 8) & 0xFF, major & 0xFF, // Major (2 B)
        battery, // Minor-High
        seq, // Minor-Low
        txByte, // TX-Power (int8)
      ];

  group('BleScanner.parseIBeacon', () {
    test('gültige Payload → korrekte Felder', () {
      final p = BleScanner.parseIBeacon(payload(), uuid);
      expect(p, isNotNull);
      expect(p!.beaconId, 11);
      expect(p.batteryPercent, 100);
      expect(p.sequenceNum, 42);
      expect(p.txPower, -59); // 0xC5 → int8 sign-extended
    });

    test('positiver TX-Wert ohne Sign-Extension', () {
      final p = BleScanner.parseIBeacon(payload(txByte: 5), uuid);
      expect(p!.txPower, 5);
    });

    test('Major aus zwei Bytes (> 255)', () {
      final p = BleScanner.parseIBeacon(payload(major: 300), uuid);
      expect(p!.beaconId, 300);
    });

    test('fremde UUID → null', () {
      final p = BleScanner.parseIBeacon(
        payload(),
        '00000000-0000-0000-0000-000000000000',
      );
      expect(p, isNull);
    });

    test('zu kurze Payload → null', () {
      expect(BleScanner.parseIBeacon([0x02, 0x15, 0x00], uuid), isNull);
    });

    test('falscher iBeacon-Prefix → null', () {
      final bad = payload()..[0] = 0x01;
      expect(BleScanner.parseIBeacon(bad, uuid), isNull);
    });
  });
}
