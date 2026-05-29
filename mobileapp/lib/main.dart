import 'dart:async';

import 'package:flutter/material.dart';

import 'models/beacon.dart';
import 'screens/home_screen.dart';
import 'services/api_service.dart';
import 'services/ble_scanner.dart';
import 'services/position_engine.dart';
import 'services/storage.dart';
import 'services/sync_service.dart';
import 'services/telemetry_uploader.dart';

Future<void> main() async {
  // `SharedPreferences.getInstance()` braucht ein initialisiertes
  // Flutter-Binding bevor `runApp()` aufgerufen wird.
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await Storage.open();
  final deviceId = await storage.getOrCreateDeviceId();
  runApp(InNavApp(storage: storage, deviceId: deviceId));
}

/// App-Wurzel.
///
/// Hält die langlebigen Services als Lifecycle-gebundene Singletons:
/// - [BleScanner] — BLE-Empfang
/// - [PositionEngine] — Trilateration
/// - [ApiService] + [TelemetryUploader] — Telemetrie-Upload zum C2-Server
///
/// Der Telemetrie-Pfad ist hier verdrahtet: jeder Beacon-Scan fliesst
/// zusätzlich in die Upload-Queue (Akku, RSSI, Sequenz → C2). Die Position
/// wird weiterhin lokal berechnet — der C2-Upload ist nur Monitoring.
class InNavApp extends StatefulWidget {
  const InNavApp({super.key, required this.storage, required this.deviceId});

  final Storage storage;
  final String deviceId;

  @override
  State<InNavApp> createState() => _InNavAppState();
}

class _InNavAppState extends State<InNavApp> {
  late final BleScanner _scanner;
  late final PositionEngine _engine;
  late final ApiService _api;
  late final TelemetryUploader _uploader;
  late final SyncService _sync;
  StreamSubscription<Map<String, BeaconScan>>? _telemetrySub;

  @override
  void initState() {
    super.initState();
    _scanner = BleScanner();
    _engine = PositionEngine(
      scanner: _scanner,
      storage: widget.storage,
      // Zuletzt gewähltes Verfahren wiederherstellen (Default: Trilateration).
      strategy: widget.storage.positionStrategy,
    );
    // API-Token (Anti-Spam fuer die Schreib-Hooks) kommt per Build-Flag rein,
    // NICHT in den Code (code/ ist oeffentlich auf GitHub):
    //   flutter run --release --dart-define=INNAV_TOKEN=<wert>
    // Leer = kein Token (der Server prueft ihn ohnehin nur, wenn INNAV_TOKEN
    // dort gesetzt ist) -> bricht den offenen Betrieb nicht.
    const innavToken = String.fromEnvironment('INNAV_TOKEN');
    _api = ApiService(apiToken: innavToken.isEmpty ? null : innavToken);
    _uploader = TelemetryUploader(api: _api, deviceId: widget.deviceId);

    // Jeden empfangenen Scan zusätzlich in die Telemetrie-Queue legen.
    // Nur eigene Beacons werden vom Uploader aufgenommen (Filter intern).
    _telemetrySub = _scanner.stream.listen((beacons) {
      for (final beacon in beacons.values) {
        _uploader.enqueueScan(beacon);
      }
    });
    _uploader.start();

    // App scannt ab Start automatisch (kontinuierlich) → die Position ist
    // sofort da, ohne dass der Nutzer „Scan" tippen muss.
    unawaited(_autoStartScan());

    // Geteilte Konfiguration (Beacons + Fingerprints) beim Start vom C2 holen,
    // damit ein neu installiertes Gerät sofort die Einrichtung übernimmt.
    _sync = SyncService(
      api: _api,
      storage: widget.storage,
      deviceId: widget.deviceId,
    );
    unawaited(_sync.pull());
  }

  /// Startet den Dauer-Scan beim Launch. Ist Bluetooth aus / fehlt die
  /// Berechtigung, bleibt es ruhig (Position einfach leer) — der Nutzer kann
  /// BT aktivieren und über den Aktualisieren-Knopf der Karte neu anstossen.
  Future<void> _autoStartScan() async {
    try {
      await _scanner.start();
    } catch (_) {
      // BluetoothOffException o. Ä. — nicht fatal.
    }
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _uploader.dispose();
    _api.dispose();
    _engine.dispose();
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InNav',
      theme: ThemeData(
        // Marken-Akzent aus dem Design-System (MobileApp.pen) statt
        // Material-Default-Blau → AppBar/Buttons/Marker einheitlich.
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: HomeScreen(
        scanner: _scanner,
        storage: widget.storage,
        engine: _engine,
        uploader: _uploader,
        syncService: _sync,
      ),
    );
  }
}
