import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:indoor_nav/models/fingerprint.dart';
import 'package:indoor_nav/screens/calibration_screen.dart';
import 'package:indoor_nav/services/ble_scanner.dart';
import 'package:indoor_nav/services/position_engine.dart';
import 'package:indoor_nav/services/storage.dart';

/// Fährt den ECHTEN CalibrationScreen-Lebenszyklus mit vorab gespeicherten
/// Fingerprints (wie nach einem Capture). Reproduziert den „graue Karte"-Bug,
/// falls er im Screen-Build/StreamBuilder statt in statischen IndoorMap-Props
/// steckt. testWidgets schlaegt bei einer Build-Exception automatisch fehl.
void main() {
  testWidgets('CalibrationScreen rendert mit gespeicherten Fingerprints',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await Storage.open();
    await storage.saveFingerprint(
      Fingerprint(
        id: 'fp1',
        floorId: 'hslu_3',
        xMeters: 10,
        yMeters: 10,
        rssiByBeaconId: const {1: -70, 2: -75},
        sampleCount: 10,
        capturedAt: DateTime(2026, 1, 1),
      ),
    );
    await storage.saveFingerprint(
      Fingerprint(
        id: 'fp2',
        floorId: 'hslu_3',
        xMeters: 20,
        yMeters: 15,
        rssiByBeaconId: const {1: -72, 3: -80},
        sampleCount: 12,
        capturedAt: DateTime(2026, 1, 1),
      ),
    );

    final scanner = BleScanner();
    final engine = PositionEngine(scanner: scanner, storage: storage);
    addTearDown(() {
      engine.dispose();
      scanner.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: CalibrationScreen(
          scanner: scanner,
          storage: storage,
          engine: engine,
        ),
      ),
    );
    await tester.pump(); // initState
    await tester.pump(const Duration(milliseconds: 500)); // _reload aufloesen

    expect(find.byType(CalibrationScreen), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
