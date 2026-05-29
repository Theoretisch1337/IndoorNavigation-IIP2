import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/beacon.dart';
import '../models/fingerprint.dart';
import '../models/floor_plan.dart';
import '../services/ble_scanner.dart';
import '../services/position_engine.dart';
import '../services/storage.dart';
import '../services/sync_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/indoor_map.dart';

/// **Kalibrierungs-Screen (Admin-Modus, Spec 01).**
///
/// Der Admin steht physisch an einer Position, tippt sie auf der Karte an und
/// die App nimmt über einige Sekunden die RSSI-Signatur aller sichtbaren
/// Beacons auf → ein [Fingerprint]. Genügend Fingerprints (Raster ~3–4 m)
/// erlauben dann Fingerprinting-Lokalisierung per k-Nearest-Neighbors.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({
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
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  /// Empfohlene Capture-Dauer pro Fingerprint.
  static const _captureDuration = Duration(seconds: 60);

  late FloorPlan _floor;
  List<Fingerprint> _fingerprints = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _floor = floorById(widget.storage.activeFloorId);
    // Jede Fingerprint-Änderung automatisch zum C2 hochladen (für alle Geräte).
    widget.storage.fingerprintsRevision.addListener(_pushToC2);
    _reload();
  }

  @override
  void dispose() {
    widget.storage.fingerprintsRevision.removeListener(_pushToC2);
    super.dispose();
  }

  void _pushToC2() {
    final s = widget.syncService;
    if (s != null) unawaited(s.push());
  }

  Future<void> _reload() async {
    final fps = await widget.storage.loadFingerprintsForFloor(_floor.id);
    if (!mounted) return;
    setState(() {
      _fingerprints = fps;
      _loading = false;
    });
  }

  Future<void> _setFloor(FloorPlan f) async {
    setState(() {
      _floor = f;
      _loading = true;
    });
    await widget.storage.setActiveFloorId(f.id);
    await widget.engine.refreshFingerprints();
    await _reload();
  }

  Future<void> _onTapMeters(Offset meters) async {
    // Tap nahe an bestehendem Fingerprint (<1 m) → Lösch-Sheet, sonst Capture.
    Fingerprint? near;
    var nearest = double.infinity;
    for (final f in _fingerprints) {
      final d = (f.positionMeters - meters).distance;
      if (d < nearest && d < 1.0) {
        nearest = d;
        near = f;
      }
    }
    if (near != null) {
      await _showDeleteSheet(near);
    } else {
      await _startCapture(meters);
    }
  }

  Future<void> _startCapture(Offset meters) async {
    // Scanner sicherstellen — Fingerprinting braucht laufenden Empfang.
    if (!widget.scanner.isScanning) {
      try {
        await widget.scanner.start(timeout: const Duration(minutes: 2));
        if (mounted) setState(() {});
      } on BluetoothOffException {
        if (!mounted) return;
        showToast(context, 'Bitte Bluetooth einschalten!');
        return;
      }
    }

    if (!mounted) return;
    final fp = await showModalBottomSheet<Fingerprint>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      builder: (_) => _CaptureSheet(
        scanner: widget.scanner,
        floorId: _floor.id,
        positionMeters: meters,
        recommendedDuration: _captureDuration,
      ),
    );

    if (fp == null) return;
    await widget.storage.saveFingerprint(fp);
    await widget.engine.refreshFingerprints();
    await _reload();
    if (!mounted) return;
    showToast(
      context,
      'Fingerprint gespeichert · ${fp.rssiByBeaconId.length} Beacons, '
      '${fp.sampleCount} Messungen',
    );
  }

  Future<void> _showDeleteSheet(Fingerprint fp) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.target),
              title: Text(
                'Fingerprint @ (${fp.xMeters.toStringAsFixed(1)}, '
                '${fp.yMeters.toStringAsFixed(1)}) m',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${fp.rssiByBeaconId.length} Beacons · ${fp.sampleCount} '
                'Messungen',
              ),
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(LucideIcons.trash2, color: Colors.red),
              title: const Text(
                'Diesen Fingerprint löschen',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () async {
                Navigator.pop(sheetCtx);
                await widget.storage.deleteFingerprint(fp.id);
                await widget.engine.refreshFingerprints();
                await _reload();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alle Fingerprints löschen?'),
        content: Text(
          'Entfernt alle ${_fingerprints.length} Fingerprints von '
          '${_floor.displayName}. Kann nicht rückgängig gemacht werden.',
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
    await widget.storage.deleteFingerprintsForFloor(_floor.id);
    await widget.engine.refreshFingerprints();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kalibrierung'),
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
                const _CalibrationHint(),
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
                        beaconScans: scansById,
                        placements: widget.engine.placements
                            .where((p) => p.floorId == _floor.id)
                            .toList(),
                        fingerprintPoints: [
                          for (final f in _fingerprints) f.positionMeters,
                        ],
                        onTapMeters: _onTapMeters,
                        showDistanceRings: false,
                      );
                    },
                  ),
                ),
                _StatsCard(
                  count: _fingerprints.length,
                  floorName: _floor.displayName,
                  onDeleteAll: _fingerprints.isEmpty ? null : _deleteAll,
                ),
              ],
            ),
    );
  }
}

/// Hinweis-Banner oben (Akzent-Farbe), erklärt den Tap-to-Capture-Workflow.
class _CalibrationHint extends StatelessWidget {
  const _CalibrationHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(LucideIcons.target, size: 20, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Stell dich an eine Position und tippe sie auf der Karte an. '
              'Die App nimmt einige Sekunden die Beacon-Signale auf.',
              style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Statistik-Karte unten: Anzahl Fingerprints + „Alle löschen".
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
          const Icon(LucideIcons.target, size: 20, color: Color(0xFF16A34A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count Fingerprint${count == 1 ? "" : "s"}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                Text(
                  'erfasst auf $floorName',
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

/// Capture-Modal: sammelt RSSI-Samples während der Aufnahme und gibt bei
/// „Speichern" den fertigen [Fingerprint] via `Navigator.pop` zurück.
class _CaptureSheet extends StatefulWidget {
  const _CaptureSheet({
    required this.scanner,
    required this.floorId,
    required this.positionMeters,
    required this.recommendedDuration,
  });

  final BleScanner scanner;
  final String floorId;
  final Offset positionMeters;
  final Duration recommendedDuration;

  @override
  State<_CaptureSheet> createState() => _CaptureSheetState();
}

class _CaptureSheetState extends State<_CaptureSheet> {
  static const _minSamples = 3;
  static const _minBeacons = 2;

  final FingerprintAccumulator _acc = FingerprintAccumulator();
  StreamSubscription<Map<String, BeaconScan>>? _sub;
  Timer? _ticker;
  // Ganzzahliger Sekunden-Zähler (1-s-Tick) statt 0.2-Float-Akkumulation →
  // kein Float-Drift, nur 1 Rebuild/s statt 5 (Review-Fix). Die Live-Beacon-
  // Liste aktualisiert sich unabhängig über den Scanner-Stream (_ingest).
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    _ingest(widget.scanner.current);
    _sub = widget.scanner.stream.listen(_ingest);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSeconds++);
    });
  }

  void _ingest(Map<String, BeaconScan> beacons) {
    for (final b in beacons.values) {
      if (b.beaconId != null) _acc.addSample(b.beaconId!, b.rssi);
    }
    if (mounted) setState(() {});
  }

  /// Wie viele Beacons schon genug Messungen für einen gültigen Fingerprint
  /// haben — Speichern erst möglich, wenn das ≥ [_minBeacons] sind.
  int get _readyBeacons =>
      _acc.sampleCounts.values.where((c) => c >= _minSamples).length;

  bool get _canSave => _readyBeacons >= _minBeacons;

  double get _progress =>
      (_elapsedSeconds / widget.recommendedDuration.inSeconds).clamp(0.0, 1.0);

  /// Verbleibende Sekunden der empfohlenen Aufnahmedauer (Countdown).
  int get _remainingSeconds {
    final total = widget.recommendedDuration.inSeconds;
    return (total - _elapsedSeconds).clamp(0, total).toInt();
  }

  /// Geführte 360°-Drehung: vier Blickrichtungen über die Aufnahmedauer
  /// verteilt. Der eigene Körper dämpft das BLE-Signal je nach Ausrichtung
  /// um mehrere dB — einmal im Kreis drehen mittelt das heraus und macht den
  /// Fingerprint robuster.
  static const _directionHints = <String>[
    'Bleib stehen — Handy locker vor dir halten',
    'Dreh dich etwa 90° nach rechts',
    'Nochmal etwa 90° weiter drehen',
    'Letzte 90° — fast geschafft',
  ];

  int get _directionIndex {
    final per = widget.recommendedDuration.inSeconds / _directionHints.length;
    if (per <= 0) return 0;
    return (_elapsedSeconds ~/ per).clamp(0, _directionHints.length - 1).toInt();
  }

  Future<void> _save() async {
    final fp = _acc.build(
      id: 'fp-${DateTime.now().microsecondsSinceEpoch}',
      floorId: widget.floorId,
      xMeters: widget.positionMeters.dx,
      yMeters: widget.positionMeters.dy,
      capturedAt: DateTime.now(),
      minSamples: _minSamples,
      minBeacons: _minBeacons,
    );
    if (fp == null) return; // _canSave gate verhindert das eigentlich
    Navigator.pop(context, fp);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counts = _acc.sampleCounts;
    final averages = _acc.currentAverages;
    final beaconIds = counts.keys.toList()..sort();
    final reachedTarget = _progress >= 1.0;
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(LucideIcons.radar, color: Color(0xFF2563EB)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    reachedTarget ? 'Alle Richtungen erfasst' : 'Aufnahme läuft …',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Position (${widget.positionMeters.dx.toStringAsFixed(1)}, '
              '${widget.positionMeters.dy.toStringAsFixed(1)}) m',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 14),
            // Geführte 360°-Drehung — bleib am Punkt und dreh dich einmal im Kreis.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: reachedTarget
                    ? const Color(0xFFDCFCE7)
                    : scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    reachedTarget ? LucideIcons.check : LucideIcons.compass,
                    color: reachedTarget
                        ? const Color(0xFF166534)
                        : scheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: reachedTarget
                        ? const Text(
                            'Fertig — du kannst jetzt speichern.',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF166534),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Richtung ${_directionIndex + 1} von '
                                '${_directionHints.length}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                              Text(
                                _directionHints[_directionIndex],
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                  ),
                  if (!reachedTarget) ...[
                    const SizedBox(width: 8),
                    Text(
                      'noch ${_remainingSeconds}s',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 10,
                backgroundColor: Colors.grey.shade300,
                color: reachedTarget ? const Color(0xFF16A34A) : null,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${_acc.totalSamples} Messungen · $_readyBeacons von '
              '${beaconIds.length} Beacons bereit',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 14),
            if (beaconIds.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Warte auf Beacon-Signale …',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final id in beaconIds)
                      _BeaconSampleRow(
                        beaconId: id,
                        avgRssi: averages[id],
                        samples: counts[id] ?? 0,
                        ready: (counts[id] ?? 0) >= _minSamples,
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Abbrechen'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _canSave ? _save : null,
                    icon: const Icon(LucideIcons.check, size: 18),
                    label: const Text('Speichern'),
                  ),
                ),
              ],
            ),
            if (!_canSave)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Mindestens $_minBeacons Beacons mit je $_minSamples '
                  'Messungen nötig.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Eine Zeile in der Live-Beacon-Liste des Capture-Modals.
class _BeaconSampleRow extends StatelessWidget {
  const _BeaconSampleRow({
    required this.beaconId,
    required this.avgRssi,
    required this.samples,
    required this.ready,
  });

  final int beaconId;
  final double? avgRssi;
  final int samples;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final color = ready ? const Color(0xFF16A34A) : Colors.orange.shade800;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: color,
            child: Text(
              '$beaconId',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              avgRssi != null ? '${avgRssi!.toStringAsFixed(0)} dBm' : '—',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Icon(
            ready ? LucideIcons.check : LucideIcons.hourglass,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$samples',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }
}
