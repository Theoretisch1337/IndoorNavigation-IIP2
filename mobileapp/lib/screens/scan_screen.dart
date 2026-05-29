import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/beacon.dart';
import '../services/ble_scanner.dart';
import '../services/telemetry_uploader.dart';
import '../widgets/app_toast.dart';

/// Debug- und Diagnose-Bildschirm.
///
/// Zeigt alle gerade empfangenen BLE-Geräte, sortiert nach RSSI.
/// InNav-Beacons werden hervorgehoben mit Akku-Stand, Sequenz-Nummer
/// und geschätzter Distanz aus dem Pfadverlust-Modell.
///
/// Oben zeigt ein Telemetrie-Banner den C2-Upload-Status (gequeued /
/// gesendet / C2 erreichbar) — damit der "volle Überblick" auch ohne
/// C2-Dashboard sichtbar ist.
///
/// Der Bildschirm hält keinen eigenen Zustand zu den Beacons — er hört
/// per `StreamBuilder` auf `BleScanner.stream`. Damit ist er
/// idempotent gegenüber Tab-Wechseln und Rebuilds.
class ScanScreen extends StatefulWidget {
  const ScanScreen({
    super.key,
    required this.scanner,
    required this.uploader,
  });

  final BleScanner scanner;
  final TelemetryUploader uploader;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  Future<void> _toggleScan() async {
    try {
      if (widget.scanner.isScanning) {
        await widget.scanner.stop();
      } else {
        await widget.scanner.start();
      }
      if (mounted) setState(() {});
    } on BluetoothOffException {
      if (!mounted) return;
      showToast(context, 'Bitte Bluetooth einschalten!');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isScanning = widget.scanner.isScanning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (isScanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: StreamBuilder<Map<String, BeaconScan>>(
        stream: widget.scanner.stream,
        initialData: widget.scanner.current,
        builder: (context, snap) {
          final beacons = (snap.data ?? const <String, BeaconScan>{})
              .values
              .toList()
            ..sort((a, b) => b.rssi.compareTo(a.rssi));
          final ours = beacons.where((b) => b.isOurBeacon).toList();
          final others = beacons.where((b) => !b.isOurBeacon).toList();

          return Column(
            children: [
              _StatusBanner(scanning: isScanning, count: beacons.length),
              _TelemetryBanner(uploader: widget.uploader),
              Expanded(
                child: ListView(
                  children: [
                    if (ours.isNotEmpty) ...[
                      const _SectionHeader('InNav Beacons (nach Signalstärke)'),
                      for (var i = 0; i < ours.length; i++)
                        _BeaconTile(beacon: ours[i], rank: i + 1),
                    ],
                    if (others.isNotEmpty) ...[
                      const _SectionHeader(
                        'Andere BLE-Geräte',
                        small: true,
                      ),
                      for (final b in others) _BeaconTile(beacon: b),
                    ],
                    if (beacons.isEmpty && !isScanning) const _EmptyState(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleScan,
        icon: Icon(isScanning ? LucideIcons.square : LucideIcons.bluetoothSearching),
        label: Text(isScanning ? 'Stop' : 'Scan'),
        backgroundColor: isScanning ? Colors.red : null,
      ),
    );
  }
}

/// Zeigt den C2-Telemetrie-Upload-Status live an: ob der C2-Server
/// erreichbar ist, wie viele Records bereits gesendet wurden und wie
/// viele noch in der Queue warten. Ermöglicht "vollen Überblick" auch
/// ohne C2-Dashboard.
class _TelemetryBanner extends StatelessWidget {
  const _TelemetryBanner({required this.uploader});
  final TelemetryUploader uploader;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TelemetryStats>(
      stream: uploader.stats,
      initialData: uploader.currentStats,
      builder: (context, snap) {
        final s = snap.data ?? uploader.currentStats;

        // Drei Zustände: verbunden (grün), schon kontaktiert aber fehlgeschlagen
        // (orange), noch nie kontaktiert (grau).
        final (Color color, IconData icon, String label) = switch (s) {
          _ when s.c2Reachable => (
              Colors.green,
              LucideIcons.cloud,
              'C2 verbunden',
            ),
          _ when s.lastFlush != null => (
              Colors.orange,
              LucideIcons.cloudOff,
              s.lastError ?? 'C2 nicht erreichbar',
            ),
          _ => (Colors.grey, LucideIcons.cloud, 'C2 noch nicht kontaktiert'),
        };

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: color.withValues(alpha: 0.08),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Telemetrie · $label',
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ),
              Text(
                'gesendet ${s.totalSent} · queue ${s.queued}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.scanning, required this.count});
  final bool scanning;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: scanning ? Colors.green.shade50 : Colors.grey.shade100,
      child: Text(
        scanning ? 'Scanne… $count Geräte gefunden' : 'Bereit zum Scannen',
        style: TextStyle(
          color: scanning ? Colors.green.shade700 : Colors.grey.shade600,
          fontWeight: FontWeight.w500,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text, {this.small = false});
  final String text;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: small ? 14 : 16,
          fontWeight: small ? FontWeight.normal : FontWeight.bold,
          color: small ? Colors.grey : null,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(48),
      child: Column(
        children: [
          Icon(LucideIcons.bluetoothSearching, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'Drücke den Scan-Button um\nnach Beacons zu suchen',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class _BeaconTile extends StatelessWidget {
  const _BeaconTile({required this.beacon, this.rank});
  final BeaconScan beacon;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final isOurs = beacon.isOurBeacon;
    final distance = beacon.estimatedDistanceMeters;
    // 0/null = kein echter Akku-Messwert (ADR-007, Firmware ohne
    // Spannungsteiler) → "k.A." statt "0%".
    final battery = beacon.batteryPercent;
    final batteryText =
        (battery == null || battery == 0) ? 'k.A.' : '$battery%';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: isOurs ? Colors.blue.shade50 : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isOurs ? Colors.blue : Colors.grey,
          child: rank != null
              ? Text(
                  '#$rank',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                )
              : const Icon(LucideIcons.bluetooth, color: Colors.white),
        ),
        title: Text(
          beacon.name,
          style: TextStyle(
            fontWeight: isOurs ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _RssiBars(rssi: beacon.rssi),
                const SizedBox(width: 8),
                Text('RSSI: ${beacon.rssi} dBm'),
                if (distance != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    '~${distance.toStringAsFixed(1)} m',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ],
            ),
            if (isOurs)
              Text(
                'Akku: $batteryText · '
                'Seq: ${beacon.sequenceNum} · '
                'TX: ${beacon.txPower} dBm',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
          ],
        ),
        trailing: (isOurs && beacon.batteryPercent != null)
            ? _BatteryIcon(percent: beacon.batteryPercent!)
            : null,
      ),
    );
  }
}

class _RssiBars extends StatelessWidget {
  const _RssiBars({required this.rssi});
  final int rssi;

  /// Anzahl gefüllter Balken (1..4) nach RSSI-Stufen.
  int get _strength {
    if (rssi > -50) return 4;
    if (rssi > -65) return 3;
    if (rssi > -80) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final strength = _strength;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        return Container(
          width: 4,
          height: 6.0 + i * 3,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: i < strength ? Colors.green : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

class _BatteryIcon extends StatelessWidget {
  const _BatteryIcon({required this.percent});
  final int percent;

  @override
  Widget build(BuildContext context) {
    // 0 = kein echter Messwert (ADR-007: Firmware ohne Spannungsteiler sendet
    // ein binäres Flag; bis zur Flag-Firmware kommt 0 an) → neutral grau,
    // NICHT alarmierendes Rot. Sonst: Ampel wie im C2-Dashboard.
    if (percent <= 0) {
      return Icon(LucideIcons.battery, color: Colors.grey.shade400);
    }
    final IconData icon;
    final Color color;
    if (percent > 50) {
      icon = LucideIcons.batteryFull;
      color = Colors.green;
    } else if (percent >= 20) {
      icon = LucideIcons.batteryMedium;
      color = Colors.orange;
    } else {
      icon = LucideIcons.batteryLow;
      color = Colors.red;
    }
    return Icon(icon, color: color);
  }
}
