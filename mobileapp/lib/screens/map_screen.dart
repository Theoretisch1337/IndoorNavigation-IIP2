import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/beacon.dart';
import '../models/beacon_placement.dart';
import '../models/floor_plan.dart';
import '../models/position_estimate.dart';
import '../services/ble_scanner.dart';
import '../services/position_engine.dart';
import '../services/storage.dart';
import '../services/sync_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/indoor_map.dart';
import 'settings_screen.dart';

/// Haupt-Bildschirm der App: zeigt live die User-Position auf der Karte.
///
/// Lebenszyklus:
/// - Bei `initState` Stockwerk + Placements aus [Storage] laden.
/// - Hört auf [PositionEngine.stream] → User-Marker bewegt sich live.
/// - Wenn der Scanner aus ist, FAB-Button startet ihn.
/// - Wenn der aktive Floor keine Placements hat, wird ein Hinweis zum
///   Setup-Tab angezeigt.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.scanner,
    required this.storage,
    required this.engine,
    this.syncService,
  });

  final BleScanner scanner;
  final Storage storage;
  final PositionEngine engine;
  final SyncService? syncService;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with RouteAware {
  late FloorPlan _floor;
  List<BeaconPlacement> _placements = const [];
  bool _loading = true;

  /// Hinweis-Banner unten (keine Position / keine Beacons) per X ausblendbar —
  /// die Karte bleibt dann ungestört (z. B. wenn man bewusst erst später
  /// Beacons platziert). Gilt für die aktuelle Session.
  bool _hintsDismissed = false;

  @override
  void initState() {
    super.initState();
    _floor = floorById(widget.storage.activeFloorId);
    // Auto-Reload, sobald im Setup-Tab Beacons platziert/geändert werden —
    // damit die Karte ohne manuellen Refresh aktuell bleibt (IndexedStack
    // hält MapScreen am Leben, initState läuft sonst nur einmal).
    widget.storage.placementsRevision.addListener(_reload);
    // Besucher↔Admin umschalten → Status-Leiste (technisch vs. einfach) neu bauen.
    widget.storage.adminModeRevision.addListener(_onModeChanged);
    _reload();
  }

  void _onModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.storage.placementsRevision.removeListener(_reload);
    widget.storage.adminModeRevision.removeListener(_onModeChanged);
    super.dispose();
  }

  Future<void> _reload({bool showError = false}) async {
    await _ensureScanning(showError: showError);
    await widget.engine.refreshPlacements();
    await widget.engine.refreshWalkable();
    final all = await widget.storage.loadBeaconPlacements();
    if (!mounted) return;
    setState(() {
      _placements = all.where((p) => p.floorId == _floor.id).toList();
      _loading = false;
    });
  }

  /// Aktualisieren-Knopf: erst geteilte Konfiguration vom C2 holen (falls
  /// verbunden), dann lokal neu laden. Der Pull merged via placementsRevision
  /// ohnehin in die Karte.
  Future<void> _refresh() async {
    final s = widget.syncService;
    if (s != null) await s.pull();
    await _reload(showError: true);
  }

  Future<void> _setFloor(FloorPlan f) async {
    setState(() {
      _floor = f;
      _loading = true;
    });
    await widget.storage.setActiveFloorId(f.id);
    await _reload();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          storage: widget.storage,
          engine: widget.engine,
        ),
      ),
    );
  }

  /// Stellt sicher, dass gescannt wird (die App scannt ab Start automatisch;
  /// hier als Kickstart, falls Bluetooth erst nachträglich aktiviert wurde).
  Future<void> _ensureScanning({bool showError = false}) async {
    if (widget.scanner.isScanning) return;
    try {
      await widget.scanner.start();
      if (mounted) setState(() {});
    } on BluetoothOffException {
      if (showError && mounted) {
        showToast(context, 'Bitte Bluetooth einschalten!');
      }
    } catch (_) {
      // Plattform-/BLE-Stack nicht verfügbar (z. B. im Widget-Test ohne
      // flutter_blue_plus-Plugin) — Auto-Scan darf die UI nie crashen.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        titleSpacing: 12,
        centerTitle: false,
        // Der Floor-Picker ist der Titel (linksbündig, primärer Kontext) —
        // so bleibt rechts Platz für genau zwei Aktionen, statt alles in eine
        // überfüllte, unausgewogene Actions-Reihe zu quetschen.
        title: PopupMenuButton<FloorPlan>(
          tooltip: 'Stockwerk wählen',
          initialValue: _floor,
          onSelected: _setFloor,
          itemBuilder: (_) => [
            for (final f in availableFloors)
              PopupMenuItem(value: f, child: Text(f.displayName)),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.layers, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _floor.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(LucideIcons.chevronDown, size: 20),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Einstellungen / Modus',
            icon: const Icon(LucideIcons.settings),
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: 'Aktualisieren (inkl. C2-Sync)',
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: _MapWithLivePosition(
                    scanner: widget.scanner,
                    engine: widget.engine,
                    floor: _floor,
                    placements: _placements,
                  ),
                ),
                // Untere Infoleisten über den Home-Indicator heben, sonst
                // klebt der Text am unteren Rand / wird vom System verdeckt.
                SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PositionStatusBar(
                        engine: widget.engine,
                        adminMode: widget.storage.adminMode,
                        floor: _floor,
                        hintsDismissed: _hintsDismissed,
                        onDismiss: () =>
                            setState(() => _hintsDismissed = true),
                      ),
                      if (_placements.isEmpty && !_hintsDismissed)
                        _NoPlacementsHint(
                          onDismiss: () =>
                              setState(() => _hintsDismissed = true),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Hört auf zwei Streams: BLE-Scans (für Beacon-Distanzringe) und
/// PositionEngine (für User-Marker). Beide werden zusammen in der
/// gleichen IndoorMap gerendert.
class _MapWithLivePosition extends StatelessWidget {
  const _MapWithLivePosition({
    required this.scanner,
    required this.engine,
    required this.floor,
    required this.placements,
  });

  final BleScanner scanner;
  final PositionEngine engine;
  final FloorPlan floor;
  final List<BeaconPlacement> placements;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, BeaconScan>>(
      stream: scanner.stream,
      initialData: scanner.current,
      builder: (context, scanSnap) {
        final scansById = BeaconScan.indexByBeaconId(
          (scanSnap.data ?? const {}).values,
        );
        return StreamBuilder<PositionEstimate?>(
          stream: engine.stream,
          initialData: engine.latest,
          builder: (context, posSnap) {
            return IndoorMap(
              floor: floor,
              placements: placements,
              beaconScans: scansById,
              userPosition: posSnap.data?.positionMeters,
              showDistanceRings: true,
            );
          },
        );
      },
    );
  }
}

class _PositionStatusBar extends StatelessWidget {
  const _PositionStatusBar({
    required this.engine,
    required this.adminMode,
    required this.floor,
    this.hintsDismissed = false,
    this.onDismiss,
  });
  final PositionEngine engine;
  final bool adminMode;
  final FloorPlan floor;
  final bool hintsDismissed;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PositionEstimate?>(
      stream: engine.stream,
      initialData: engine.latest,
      builder: (context, snap) {
        final est = snap.data;
        // Drei Anzeige-Zustände, der Reihe nach: keine Position -> Besucher-
        // Sicht (Raumname) -> Admin-Sicht (technische Rohwerte).
        if (est == null) return _noPositionBar(context);
        if (!adminMode) return _visitorBar(context, est);
        return _adminBar(context, est);
      },
    );
  }

  /// Kein Standort: Hinweis zeigen - ausser der Nutzer hat ihn ausgeblendet,
  /// dann nichts rendern (Karte bleibt frei).
  Widget _noPositionBar(BuildContext context) {
    if (hintsDismissed) return const SizedBox.shrink();
    return _bar(
      context: context,
      child: Row(
        children: [
          const Icon(LucideIcons.helpCircle, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Keine Position — Scanner starten und sicherstellen, '
              'dass mindestens ein platzierter Beacon sichtbar ist',
              style: TextStyle(fontSize: 13),
            ),
          ),
          if (onDismiss != null)
            InkWell(
              onTap: onDismiss,
              borderRadius: BorderRadius.circular(16),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(LucideIcons.x, size: 16, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }

  /// Besucher-Modus: verständliche Anzeige (Raumname + Qualität) statt
  /// technischer Rohwerte. Nutzt floor.roomAt() für den Raumnamen.
  Widget _visitorBar(BuildContext context, PositionEstimate est) {
    final room = floor.roomAt(est.positionMeters.dx, est.positionMeters.dy);
    return _bar(
      context: context,
      child: Row(
        children: [
          Icon(LucideIcons.locateFixed, color: _confidenceColor(est.confidence), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room != null ? 'Standort: ${room.label}' : 'Standort gefunden',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  _qualityLabel(est.confidence),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Admin-Modus: technische Details (Methode, RMSE, Rohkoordinaten).
  Widget _adminBar(BuildContext context, PositionEstimate est) {
    final confColor = _confidenceColor(est.confidence);
    return _bar(
      context: context,
      child: Row(
        children: [
          Icon(LucideIcons.locateFixed, color: confColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${est.positionMeters.dx.toStringAsFixed(2)} m, '
                  '${est.positionMeters.dy.toStringAsFixed(2)} m',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '${_methodLabel(est.method)}  ·  ${est.beaconsUsed} Beacon'
                  '${est.beaconsUsed == 1 ? "" : "s"}'
                  '${est.residualMeters != null ? "  ·  RMSE ${est.residualMeters!.toStringAsFixed(2)} m" : ""}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
          _ConfidenceMeter(confidence: est.confidence, color: confColor),
        ],
      ),
    );
  }

  /// Anzeigename des Positions-Verfahrens (Admin-Sicht).
  static String _methodLabel(PositionMethod method) => switch (method) {
        PositionMethod.proximity => 'Proximity',
        PositionMethod.weightedCentroid => 'Weighted Centroid',
        PositionMethod.trilateration => 'Trilateration',
        PositionMethod.fingerprinting => 'Fingerprinting',
        PositionMethod.hybrid => 'Hybrid',
      };

  /// Ampelfarbe nach Confidence: grün (gut) / orange (mittel) / rot (grob).
  /// Gleiche Schwellen wie [_qualityLabel].
  static Color _confidenceColor(double confidence) {
    if (confidence > 0.7) return Colors.green;
    if (confidence > 0.4) return Colors.orange;
    return Colors.red;
  }

  /// Laienverständliche Genauigkeits-Stufe (Besucher-Modus) zu derselben
  /// Confidence-Schwelle wie [_confidenceColor].
  static String _qualityLabel(double confidence) {
    if (confidence > 0.7) return 'gute Genauigkeit';
    if (confidence > 0.4) return 'mittlere Genauigkeit';
    return 'grobe Genauigkeit';
  }

  /// Gemeinsamer Container der Statusleiste (volle Breite, einheitliche
  /// Hintergrundfarbe und Polsterung) - der Inhalt unterscheidet sich je
  /// Anzeige-Zustand.
  Widget _bar({required BuildContext context, required Widget child}) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: child,
    );
  }
}

class _ConfidenceMeter extends StatelessWidget {
  const _ConfidenceMeter({required this.confidence, required this.color});
  final double confidence;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'Confidence',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: Colors.grey.shade500,
          ),
        ),
        Text(
          '${(confidence * 100).toStringAsFixed(0)}%',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 48,
          child: LinearProgressIndicator(
            value: confidence,
            backgroundColor: Colors.grey.shade300,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 4,
          ),
        ),
      ],
    );
  }
}

class _NoPlacementsHint extends StatelessWidget {
  const _NoPlacementsHint({this.onDismiss});
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: Colors.amber.shade50,
      child: Row(
        children: [
          Icon(LucideIcons.info, color: Colors.amber.shade800),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Noch keine Beacons für dieses Stockwerk platziert — '
              'wechsle zum Setup-Tab und tippe auf die Karte.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          if (onDismiss != null)
            InkWell(
              onTap: onDismiss,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(LucideIcons.x, size: 16, color: Colors.amber.shade800),
              ),
            ),
        ],
      ),
    );
  }
}
