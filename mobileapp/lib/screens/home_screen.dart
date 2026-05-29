import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../services/ble_scanner.dart';
import '../services/position_engine.dart';
import '../services/storage.dart';
import '../services/sync_service.dart';
import '../services/telemetry_uploader.dart';
import 'calibration_screen.dart';
import 'map_screen.dart';
import 'scan_screen.dart';
import 'setup_screen.dart';
import 'walkable_screen.dart';

/// App-Shell mit zwei Modi (Spec 01):
///
/// - **Besucher-Modus** (Default): nur die **Karte** — eine Endnutzerin sieht
///   ihren Standort, ohne technische Bedienelemente. Keine Tab-Leiste.
/// - **Admin-Modus**: zusätzlich **Setup** (Beacons platzieren), **Scan**
///   (BLE-Diagnose) und **Kalibrierung** (Fingerprinting) als Tab-Leiste.
///
/// Umgeschaltet wird der Modus im Einstellungen-Screen (sichtbarer Schalter,
/// erreichbar über das Zahnrad in der Karten-Leiste). Der Wechsel persistiert
/// in [Storage]; `adminModeRevision` triggert hier das Neuaufbauen der Tabs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.scanner,
    required this.storage,
    required this.engine,
    required this.uploader,
    this.syncService,
  });

  final BleScanner scanner;
  final Storage storage;
  final PositionEngine engine;
  final TelemetryUploader uploader;

  /// Optionaler C2-Sync (Platzierungen + Fingerprints teilen). `null` = ohne
  /// Server (z. B. in Tests) → die App läuft rein lokal.
  final SyncService? syncService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  late bool _admin = widget.storage.adminMode;

  /// Alle Tab-Screens werden EINMAL gebaut und über einen IndexedStack am
  /// Leben gehalten (Scan-Zustand, Karten-Zoom bleiben beim Tabwechsel
  /// erhalten). In welchem Modus welche sichtbar/erreichbar sind, steuert
  /// nur die Tab-Leiste + der aktive Index.
  late final List<Widget> _tabs = [
    MapScreen(
      scanner: widget.scanner,
      storage: widget.storage,
      engine: widget.engine,
      syncService: widget.syncService,
    ),
    SetupScreen(
      scanner: widget.scanner,
      storage: widget.storage,
      syncService: widget.syncService,
    ),
    ScanScreen(scanner: widget.scanner, uploader: widget.uploader),
    CalibrationScreen(
      scanner: widget.scanner,
      storage: widget.storage,
      engine: widget.engine,
      syncService: widget.syncService,
    ),
    WalkableScreen(storage: widget.storage),
  ];

  @override
  void initState() {
    super.initState();
    widget.storage.adminModeRevision.addListener(_onModeChanged);
  }

  @override
  void dispose() {
    widget.storage.adminModeRevision.removeListener(_onModeChanged);
    super.dispose();
  }

  void _onModeChanged() {
    if (!mounted) return;
    setState(() {
      _admin = widget.storage.adminMode;
      // Beim Verlassen des Admin-Modus zurück auf die Karte — die übrigen
      // Tabs sind dann nicht mehr erreichbar.
      if (!_admin) _index = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: _admin
          ? NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(LucideIcons.map),
                  label: 'Karte',
                ),
                NavigationDestination(
                  icon: Icon(LucideIcons.mapPin),
                  label: 'Setup',
                ),
                NavigationDestination(
                  icon: Icon(LucideIcons.bluetoothSearching),
                  label: 'Scan',
                ),
                NavigationDestination(
                  icon: Icon(LucideIcons.target),
                  label: 'Kalibrierung',
                ),
                NavigationDestination(
                  icon: Icon(LucideIcons.footprints),
                  label: 'Begehbar',
                ),
              ],
            )
          : null,
    );
  }
}
