import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/beacon_placement.dart';
import '../models/floor_plan.dart';
import '../models/walkable_zone.dart';
import '../services/storage.dart';
import '../widgets/app_toast.dart';
import '../widgets/indoor_map.dart';

/// **Begehbar-Screen (Admin-Modus, Feature B).**
///
/// Der Admin zeichnet begehbare Rechtecke, indem er **zwei gegenüberliegende
/// Ecken** auf der Karte antippt. Diese Zonen definieren — falls vorhanden —
/// die begehbare Fläche fürs Snap-to-Walkable. Ohne Zonen fällt die Snap-Logik
/// automatisch auf die Räume des Grundrisses zurück (Feature A).
///
/// Lufträume (z. B. das Atrium) werden rot markiert, damit klar ist, wo niemand
/// stehen kann.
class WalkableScreen extends StatefulWidget {
  const WalkableScreen({super.key, required this.storage});

  final Storage storage;

  @override
  State<WalkableScreen> createState() => _WalkableScreenState();
}

class _WalkableScreenState extends State<WalkableScreen> {
  late FloorPlan _floor;
  List<WalkableZone> _zones = const [];
  List<BeaconPlacement> _placements = const [];
  bool _loading = true;

  /// Erste angetippte Ecke einer neuen Zone; `null` = keine Zeichnung aktiv.
  Offset? _firstCorner;

  @override
  void initState() {
    super.initState();
    _floor = floorById(widget.storage.activeFloorId);
    _reload();
  }

  Future<void> _reload() async {
    final zones = await widget.storage.loadWalkableZonesForFloor(_floor.id);
    final all = await widget.storage.loadBeaconPlacements();
    if (!mounted) return;
    setState(() {
      _zones = zones;
      _placements = all.where((p) => p.floorId == _floor.id).toList();
      _loading = false;
    });
  }

  Future<void> _setFloor(FloorPlan f) async {
    setState(() {
      _floor = f;
      _loading = true;
      _firstCorner = null;
    });
    await widget.storage.setActiveFloorId(f.id);
    await _reload();
  }

  Future<void> _onTapMeters(Offset meters) async {
    // Zweiter Tap → Zone aufspannen.
    final first = _firstCorner;
    if (first != null) {
      await _createZone(first, meters);
      return;
    }
    // Tap in eine bestehende Zone (und nicht mitten im Zeichnen) → löschen.
    for (final z in _zones) {
      if (z.bounds.contains(meters)) {
        await _deleteZone(z);
        return;
      }
    }
    // Sonst: erste Ecke setzen.
    setState(() => _firstCorner = meters);
    showToast(context, 'Erste Ecke gesetzt - tippe die gegenüberliegende Ecke');
  }

  Future<void> _createZone(Offset a, Offset b) async {
    final rect = Rect.fromPoints(a, b);
    setState(() => _firstCorner = null);
    if (rect.width < 0.5 || rect.height < 0.5) {
      if (!mounted) return;
      showToast(context, 'Zone zu klein - abgebrochen');
      return;
    }
    await widget.storage.saveWalkableZone(
      WalkableZone(
        id: 'wz-${DateTime.now().microsecondsSinceEpoch}',
        floorId: _floor.id,
        bounds: rect,
      ),
    );
    await _reload();
    if (!mounted) return;
    showToast(context, 'Begehbare Zone hinzugefügt');
  }

  Future<void> _deleteZone(WalkableZone zone) async {
    await widget.storage.deleteWalkableZone(zone.id);
    await _reload();
    if (!mounted) return;
    showToast(context, 'Zone entfernt');
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alle Zonen löschen?'),
        content: Text(
          'Entfernt alle ${_zones.length} begehbaren Zonen von '
          '${_floor.displayName}. Danach gelten wieder die Räume.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.storage.deleteWalkableZonesForFloor(_floor.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Begehbar'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          PopupMenuButton<FloorPlan>(
            tooltip: 'Stockwerk wählen',
            initialValue: _floor,
            onSelected: _setFloor,
            itemBuilder: (_) => [
              for (final f in availableFloors)
                PopupMenuItem(value: f, child: Text(f.displayName)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const Icon(LucideIcons.layers),
                  const SizedBox(width: 6),
                  Text(_floor.displayName),
                  const Icon(LucideIcons.chevronDown),
                ],
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _WalkableHint(drawing: _firstCorner != null),
                Expanded(
                  child: IndoorMap(
                    floor: _floor,
                    placements: _placements,
                    walkableZones: [for (final z in _zones) z.bounds],
                    showVoids: true,
                    onTapMeters: _onTapMeters,
                    showDistanceRings: false,
                  ),
                ),
                _StatsCard(
                  count: _zones.length,
                  floorName: _floor.displayName,
                  onDeleteAll: _zones.isEmpty ? null : _deleteAll,
                ),
              ],
            ),
    );
  }
}

class _WalkableHint extends StatelessWidget {
  const _WalkableHint({required this.drawing});
  final bool drawing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(LucideIcons.pointer, size: 20, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              drawing
                  ? 'Tippe die gegenüberliegende Ecke der Zone.'
                  : 'Zwei Ecken antippen = begehbare Zone. Zone antippen = löschen. '
                      'Ohne Zonen gelten die Räume.',
              style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.count,
    required this.floorName,
    required this.onDeleteAll,
  });

  final int count;
  final String floorName;
  final VoidCallback? onDeleteAll;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(LucideIcons.footprints, size: 20, color: Color(0xFF16A34A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 0
                      ? 'Keine Zonen — Räume gelten als begehbar'
                      : '$count Zone${count == 1 ? "" : "n"}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Text(
                  'auf $floorName',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          if (onDeleteAll != null)
            TextButton.icon(
              onPressed: onDeleteAll,
              icon: const Icon(LucideIcons.trash2, size: 18),
              label: const Text('Alle löschen'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
        ],
      ),
    );
  }
}
