import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/beacon.dart';
import '../models/beacon_placement.dart';
import '../models/floor_plan.dart';
import '../services/ble_scanner.dart';
import '../services/storage.dart';
import '../services/sync_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/indoor_map.dart';

/// Beacon-Setup: User platziert Beacons auf einem Stockwerk per Tap.
///
/// Workflow:
/// 1. Floor aus Dropdown wählen
/// 2. Tap auf leere Stelle → Add-Dialog (Beacon-ID + optionales Label/TX)
/// 3. Tap auf existierenden Beacon → Edit-Sheet (Verschieben/Entfernen)
/// 4. Live-Status unten zeigt empfangene Beacons inkl. „noch nicht platziert"
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.scanner,
    required this.storage,
    this.syncService,
  });

  final BleScanner scanner;
  final Storage storage;
  final SyncService? syncService;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late FloorPlan _floor;
  List<BeaconPlacement> _placements = [];
  bool _loading = true;

  /// In der unteren Leiste ausgewählter Beacon — der nächste Tipp auf die
  /// Karte platziert genau diesen direkt (ohne Dialog). `null` = nichts gewählt.
  int? _selectedBeaconId;

  @override
  void initState() {
    super.initState();
    _floor = floorById(widget.storage.activeFloorId);
    // Jede Platzierungs-Änderung automatisch zum C2 hochladen (für alle Geräte).
    widget.storage.placementsRevision.addListener(_pushToC2);
    _reload();
  }

  @override
  void dispose() {
    widget.storage.placementsRevision.removeListener(_pushToC2);
    super.dispose();
  }

  /// Lädt die lokalen Platzierungen + Fingerprints zum C2 hoch (best effort).
  void _pushToC2() {
    final s = widget.syncService;
    if (s != null) unawaited(s.push());
  }

  /// Manueller Voll-Sync (hoch + runter) über den Knopf in der Leiste.
  Future<void> _syncNow() async {
    final s = widget.syncService;
    if (s == null) return;
    final r = await s.syncNow();
    await _reload();
    if (!mounted) return;
    showToast(
      context,
      'Synchronisiert · ${r.placements} Beacons, '
      '${r.fingerprints} Fingerprints vom C2',
    );
  }

  Future<void> _reload() async {
    final all = await widget.storage.loadBeaconPlacements();
    if (!mounted) return;
    setState(() {
      _placements = all.where((p) => p.floorId == _floor.id).toList();
      _loading = false;
    });
  }

  Future<void> _setFloor(FloorPlan f) async {
    setState(() {
      _floor = f;
      _loading = true;
    });
    await widget.storage.setActiveFloorId(f.id);
    await _reload();
  }

  Future<void> _onTapMeters(Offset meters) async {
    final selected = _selectedBeaconId;
    if (selected != null) {
      // Vorgewählter Beacon → direkt platzieren, kein Dialog.
      await _placeSelected(selected, meters);
    } else {
      // Nichts vorgewählt → einfacher Dialog (ID + Notiz).
      await _showAddDialog(meters);
    }
  }

  /// Platzierung mit dieser Beacon-ID auf dem aktiven Floor, oder `null`.
  /// IDs sind eindeutig (siehe `Storage.upsertPlacement`), darum genügt der
  /// erste Treffer.
  BeaconPlacement? _placementById(int beaconId) {
    for (final p in _placements) {
      if (p.beaconId == beaconId) return p;
    }
    return null;
  }

  /// Tap direkt auf einen platzierten Beacon-Marker → Bearbeiten/Entfernen.
  Future<void> _onBeaconTap(int beaconId) async {
    final found = _placementById(beaconId);
    if (found != null) await _showEditSheet(found);
  }

  /// Beacon in der Leiste (ab)wählen. Erneutes Tippen hebt die Wahl auf.
  void _onSelectBeacon(int beaconId) {
    setState(() {
      _selectedBeaconId = _selectedBeaconId == beaconId ? null : beaconId;
    });
  }

  /// Platziert den unten gewählten Beacon direkt am getippten Punkt. Eine
  /// bestehende Notiz bleibt erhalten (Beacon wird nur verschoben).
  Future<void> _placeSelected(int beaconId, Offset meters) async {
    final existingLabel = _placementById(beaconId)?.label;
    await widget.storage.upsertPlacement(
      BeaconPlacement(
        beaconId: beaconId,
        floorId: _floor.id,
        xMeters: meters.dx,
        yMeters: meters.dy,
        label: existingLabel,
      ),
    );
    if (mounted) setState(() => _selectedBeaconId = null);
    await _reload();
    if (!mounted) return;
    showToast(context, 'Beacon #$beaconId platziert');
  }

  Future<void> _showAddDialog(Offset meters) async {
    final result = await showDialog<_BeaconFormResult>(
      context: context,
      builder: (_) => _BeaconFormDialog(
        title: 'Beacon platzieren',
        defaultId: _suggestNextId(),
      ),
    );
    if (result == null) return;
    await widget.storage.upsertPlacement(
      BeaconPlacement(
        beaconId: result.beaconId,
        floorId: _floor.id,
        xMeters: meters.dx,
        yMeters: meters.dy,
        label: result.label,
      ),
    );
    await _reload();
  }

  Future<void> _showEditSheet(BeaconPlacement existing) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.bluetooth),
                title: Text(
                  existing.label?.isNotEmpty == true
                      ? '#${existing.beaconId} — ${existing.label}'
                      : 'Beacon #${existing.beaconId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  'Position: (${existing.xMeters.toStringAsFixed(1)}, '
                  '${existing.yMeters.toStringAsFixed(1)}) m',
                ),
              ),
              const Divider(height: 0),
              ListTile(
                leading: const Icon(LucideIcons.pencil),
                title: const Text('Notiz bearbeiten'),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  final result = await showDialog<_BeaconFormResult>(
                    context: context,
                    builder: (_) => _BeaconFormDialog(
                      title: 'Beacon bearbeiten',
                      defaultId: existing.beaconId,
                      defaultLabel: existing.label,
                      idLocked: true,
                    ),
                  );
                  if (result == null) return;
                  await widget.storage.upsertPlacement(
                    existing.copyWith(label: result.label),
                  );
                  await _reload();
                },
              ),
              ListTile(
                leading: const Icon(LucideIcons.trash2, color: Colors.red),
                title: const Text(
                  'Beacon entfernen',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await widget.storage.removePlacement(existing.beaconId);
                  await _reload();
                  if (!mounted) return;
                  showToast(context, 'Beacon #${existing.beaconId} entfernt');
                },
              ),
            ],
          ),
        );
      },
    );
  }

  int _suggestNextId() {
    if (_placements.isEmpty) return 1;
    final used = _placements.map((p) => p.beaconId).toSet();
    for (var i = 1; i <= 65535; i++) {
      if (!used.contains(i)) return i;
    }
    return _placements.length + 1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (widget.syncService != null)
            IconButton(
              tooltip: 'Mit C2 synchronisieren',
              icon: const Icon(LucideIcons.refreshCw),
              onPressed: _syncNow,
            ),
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
                Expanded(
                  child: StreamBuilder<Map<String, BeaconScan>>(
                    stream: widget.scanner.stream,
                    initialData: widget.scanner.current,
                    builder: (context, snap) {
                      final scansById = BeaconScan.indexByBeaconId(
                        (snap.data ?? const {}).values,
                      );
                      return IndoorMap(
                        floor: _floor,
                        placements: _placements,
                        beaconScans: scansById,
                        onTapMeters: _onTapMeters,
                        onBeaconTap: _onBeaconTap,
                        showDistanceRings: true,
                      );
                    },
                  ),
                ),
                _LiveBeaconStatus(
                  scanner: widget.scanner,
                  placements: _placements,
                  selectedBeaconId: _selectedBeaconId,
                  onSelect: _onSelectBeacon,
                ),
                if (_selectedBeaconId != null)
                  _SelectionHint(
                    beaconId: _selectedBeaconId!,
                    onCancel: () => setState(() => _selectedBeaconId = null),
                  )
                else if (_placements.isEmpty)
                  const _SetupHint(),
              ],
            ),
    );
  }
}

/// Live-Statusleiste unten: welche Beacons gerade empfangen werden,
/// inklusive Markierung „noch nicht platziert".
class _LiveBeaconStatus extends StatelessWidget {
  const _LiveBeaconStatus({
    required this.scanner,
    required this.placements,
    required this.selectedBeaconId,
    required this.onSelect,
  });

  final BleScanner scanner;
  final List<BeaconPlacement> placements;
  final int? selectedBeaconId;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final placedIds = placements.map((p) => p.beaconId).toSet();
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<Map<String, BeaconScan>>(
      stream: scanner.stream,
      initialData: scanner.current,
      builder: (context, snap) {
        final live = (snap.data ?? const <String, BeaconScan>{})
            .values
            .where((s) => s.isOurBeacon)
            .toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));

        if (!scanner.isScanning) {
          return const _StatusBar(
            icon: LucideIcons.bluetoothOff,
            text: 'Scanner aus — Bluetooth aktivieren (Scan startet automatisch)',
          );
        }
        if (live.isEmpty) {
          return const _StatusBar(
            icon: LucideIcons.hourglass,
            text: 'Scanne — noch keine InNav-Beacons sichtbar',
          );
        }

        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: live.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final s = live[i];
                final id = s.beaconId!;
                final placed = placedIds.contains(id);
                final selected = selectedBeaconId == id;
                return ActionChip(
                  onPressed: () => onSelect(id),
                  avatar: CircleAvatar(
                    backgroundColor: placed ? Colors.blue : Colors.orange,
                    child: Text(
                      '$id',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  label: Text(
                    placed ? '${s.rssi} dBm' : '${s.rssi} dBm · neu',
                    style: TextStyle(
                      fontSize: 12,
                      color: placed ? null : Colors.orange.shade900,
                    ),
                  ),
                  backgroundColor: selected ? scheme.primaryContainer : null,
                  side: selected
                      ? BorderSide(color: scheme.primary, width: 2)
                      : null,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupHint extends StatelessWidget {
  const _SetupHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: Colors.amber.shade50,
      child: Row(
        children: [
          Icon(LucideIcons.pointer, color: Colors.amber.shade800),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Tippe auf die Karte um den ersten Beacon zu platzieren.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hinweis, wenn ein Beacon zum Platzieren vorgewählt ist.
class _SelectionHint extends StatelessWidget {
  const _SelectionHint({required this.beaconId, required this.onCancel});
  final int beaconId;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.primaryContainer,
      child: Row(
        children: [
          Icon(LucideIcons.pointer, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Beacon #$beaconId gewählt — tippe auf die Karte zum Platzieren.',
              style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer),
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Abbrechen')),
        ],
      ),
    );
  }
}

class _BeaconFormResult {
  final int beaconId;
  final String? label;
  const _BeaconFormResult({required this.beaconId, this.label});
}

class _BeaconFormDialog extends StatefulWidget {
  const _BeaconFormDialog({
    required this.title,
    required this.defaultId,
    this.defaultLabel,
    this.idLocked = false,
  });

  final String title;
  final int defaultId;
  final String? defaultLabel;
  final bool idLocked;

  @override
  State<_BeaconFormDialog> createState() => _BeaconFormDialogState();
}

class _BeaconFormDialogState extends State<_BeaconFormDialog> {
  late final TextEditingController _idCtrl;
  late final TextEditingController _labelCtrl;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _idCtrl = TextEditingController(text: '${widget.defaultId}');
    _labelCtrl = TextEditingController(text: widget.defaultLabel ?? '');
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _idCtrl,
              enabled: !widget.idLocked,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Beacon-ID',
                hintText: '1 … 65535 (Major-Feld der Firmware)',
              ),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 1 || n > 65535) {
                  return '1 … 65535 erforderlich';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Notiz (optional)',
                hintText: 'z. B. Eingang Pilatus 3.01',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final label = _labelCtrl.text.trim();
            Navigator.pop(
              context,
              _BeaconFormResult(
                beaconId: int.parse(_idCtrl.text),
                label: label.isEmpty ? null : label,
              ),
            );
          },
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
