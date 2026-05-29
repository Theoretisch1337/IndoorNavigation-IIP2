import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/floor_plan.dart';
import '../models/position_strategy.dart';
import '../services/position_engine.dart';
import '../services/storage.dart';

/// Einstellungen mit dem **sichtbaren Besucher/Admin-Umschalter** und – im
/// Admin-Modus – der Wahl des Positions-Verfahrens (Spec 01).
///
/// Der Admin-Schalter persistiert in [Storage] und löst über
/// `adminModeRevision` ein Rebuild der App-Shell aus, die daraufhin die
/// Admin-Tabs (Setup, Scan, Kalibrierung) ein- oder ausblendet.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.storage,
    required this.engine,
  });

  final Storage storage;
  final PositionEngine engine;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _admin = widget.storage.adminMode;
  late PositionStrategy _strategy = widget.engine.strategy;

  Future<void> _setAdmin(bool value) async {
    setState(() => _admin = value);
    await widget.storage.setAdminMode(value);
  }

  Future<void> _setStrategy(PositionStrategy s) async {
    setState(() => _strategy = s);
    widget.engine.strategy = s;
    await widget.storage.setPositionStrategy(s);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final floor = floorById(widget.storage.activeFloorId);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Einstellungen'),
        backgroundColor: scheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Sichtbarer Besucher/Admin-Umschalter ──────────────────────
          Card(
            elevation: 0,
            color: _admin ? scheme.primaryContainer : scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: SwitchListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              secondary: CircleAvatar(
                backgroundColor: _admin ? scheme.primary : scheme.outline,
                child: Icon(
                  _admin ? LucideIcons.shieldCheck : LucideIcons.user,
                  color: Colors.white,
                ),
              ),
              title: Text(
                _admin ? 'Admin-Modus' : 'Besucher-Modus',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                _admin
                    ? 'Setup, Scan und Kalibrierung sind sichtbar.'
                    : 'Nur die Karte. Zum Einrichten umschalten.',
              ),
              value: _admin,
              onChanged: _setAdmin,
            ),
          ),
          const SizedBox(height: 8),

          // ── Positions-Verfahren — für ALLE sichtbar (auch Besucher), damit
          //    man das Navigations-Verfahren wie im Admin-Modus wählen kann. ──
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              'POSITIONS-VERFAHREN',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _StrategyTile(
                  icon: LucideIcons.radar,
                  title: 'Trilateration',
                  subtitle: 'Distanzbasiert, ohne Kalibrierung. Standard.',
                  selected: _strategy == PositionStrategy.trilateration,
                  onTap: () => _setStrategy(PositionStrategy.trilateration),
                ),
                const Divider(height: 0, indent: 16, endIndent: 16),
                _StrategyTile(
                  icon: LucideIcons.target,
                  title: 'Fingerprinting',
                  subtitle: 'RSSI-Signaturen, braucht Kalibrierungspunkte.',
                  selected: _strategy == PositionStrategy.fingerprinting,
                  onTap: () => _setStrategy(PositionStrategy.fingerprinting),
                ),
                const Divider(height: 0, indent: 16, endIndent: 16),
                _StrategyTile(
                  icon: LucideIcons.layers,
                  title: 'Hybrid',
                  subtitle: 'Beide kombiniert, nach Confidence gewichtet.',
                  selected: _strategy == PositionStrategy.hybrid,
                  onTap: () => _setStrategy(PositionStrategy.hybrid),
                ),
              ],
            ),
          ),

          // ── Admin-only: Fingerprint-/Kalibrierungs-Verwaltung ──
          if (_admin) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Text(
                'KALIBRIERUNG',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: FutureBuilder<int>(
                future:
                    widget.storage.countFingerprintsForFloor(floor.id),
                builder: (context, snap) {
                  final count = snap.data ?? widget.engine.fingerprintCount;
                  return ListTile(
                    leading: const Icon(
                      LucideIcons.target,
                      color: Color(0xFF16A34A),
                    ),
                    title: Text('$count Fingerprints'),
                    subtitle: Text('auf ${floor.displayName}'),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Fingerprints werden im Kalibrierungs-Tab erfasst und lokal '
                'gespeichert (Phase 2: Sync mit C2-Server).',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Auswählbare Verfahrens-Zeile (Custom-Radio mit Häkchen statt
/// deprecated RadioListTile-API).
class _StrategyTile extends StatelessWidget {
  const _StrategyTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: selected ? scheme.primary : scheme.outline),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: selected
          ? Icon(LucideIcons.checkCircle, color: scheme.primary)
          : const SizedBox(width: 24),
    );
  }
}
