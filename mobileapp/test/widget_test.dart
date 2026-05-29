import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:indoor_nav/screens/home_screen.dart';
import 'package:indoor_nav/screens/map_screen.dart';
import 'package:indoor_nav/services/api_service.dart';
import 'package:indoor_nav/services/ble_scanner.dart';
import 'package:indoor_nav/services/position_engine.dart';
import 'package:indoor_nav/services/storage.dart';
import 'package:indoor_nav/services/telemetry_uploader.dart';

/// Baut HomeScreen mit den nötigen Services und ruft [body] zum Prüfen auf.
///
/// Aufräumen läuft über [addTearDown] und **ohne await**: Die Services halten
/// Broadcast-StreamController, deren `close()` im `testWidgets`-Zonen-Kontext
/// nicht zuverlässig zurückkehrt, solange der Widget-Baum (mit aktiven
/// StreamBuildern) noch steht. Fire-and-forget-Dispose genügt — der
/// Test-Prozess endet ohnehin danach.
Future<void> _pumpHome(
  WidgetTester tester,
  Future<void> Function(Storage storage) body,
) async {
  final storage = await Storage.open();
  final scanner = BleScanner();
  final engine = PositionEngine(scanner: scanner, storage: storage);
  final api = ApiService();
  final uploader = TelemetryUploader(api: api, deviceId: 'test-device');

  addTearDown(() {
    uploader.dispose();
    api.dispose();
    engine.dispose();
    scanner.dispose();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        scanner: scanner,
        storage: storage,
        engine: engine,
        uploader: uploader,
      ),
    ),
  );
  await tester.pump();

  await body(storage);
}

void main() {
  testWidgets(
    'Besucher-Modus (Default): keine Tab-Leiste, nur die Karte',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pumpHome(tester, (storage) async {
        // Default = Besucher → keine NavigationBar.
        expect(find.byType(NavigationBar), findsNothing);
        // Die Karte ist sichtbar (per Widget-Typ statt App-Bar-Titel, da der
        // Titel jetzt der Floor-Picker ist).
        expect(find.byType(MapScreen), findsOneWidget);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'Admin-Modus: Tab-Leiste mit vier Tabs',
    (tester) async {
      // Admin-Flag vorab setzen → HomeScreen startet im Admin-Modus.
      SharedPreferences.setMockInitialValues({'admin_mode_v1': true});
      await _pumpHome(tester, (storage) async {
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.text('Karte'), findsWidgets);
        expect(find.text('Setup'), findsWidgets);
        expect(find.text('Scan'), findsWidgets);
        expect(find.text('Kalibrierung'), findsWidgets);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
