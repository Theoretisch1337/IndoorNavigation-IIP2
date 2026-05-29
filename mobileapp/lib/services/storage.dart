import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/beacon_placement.dart';
import '../models/fingerprint.dart';
import '../models/position_strategy.dart';
import '../models/walkable_zone.dart';

/// Persistenz-Layer der App.
///
/// Wrapper um `shared_preferences` mit getypter API für die zwei
/// Hauptobjekte:
/// - **Beacon-Placements** (Liste): wo welcher Beacon im Stockwerk steht
/// - **Active Floor ID** (String): zuletzt aufgerufenes Stockwerk
///
/// Begründung für `shared_preferences` (statt `sqflite` / `drift`):
/// die persistierten Daten sind <10 KB und werden nicht abgefragt,
/// nur als Ganzes geladen. Eine echte DB wäre Over-Engineering;
/// JSON-In-Single-Key ist explizit, debug-freundlich und ohne Migration.
class Storage {
  Storage._(this._prefs);

  static const _keyPlacements = 'beacon_placements_v1';
  static const _keyActiveFloor = 'active_floor_id_v1';
  static const _keyDeviceId = 'device_id_v1';
  static const _keyFingerprints = 'fingerprints_v1';
  static const _keyAdminMode = 'admin_mode_v1';
  static const _keyStrategy = 'position_strategy_v1';
  static const _keyWalkableZones = 'walkable_zones_v1';

  final SharedPreferences _prefs;

  /// Wird bei jeder Änderung der Beacon-Placements inkrementiert.
  /// Bildschirme (z. B. MapScreen) hören darauf und laden neu — so erscheinen
  /// im Setup-Tab platzierte Beacons sofort auf der Karte, ohne manuellen
  /// Refresh. Leichtgewichtige Alternative zu Provider/Riverpod (ADR-001):
  /// ValueNotifier ist Flutter-builtin, kein zusätzliches Package.
  final ValueNotifier<int> placementsRevision = ValueNotifier<int>(0);

  /// Wird bei jeder Fingerprint-Änderung inkrementiert (analog zu
  /// [placementsRevision]) — CalibrationScreen und PositionEngine reagieren.
  final ValueNotifier<int> fingerprintsRevision = ValueNotifier<int>(0);

  /// Wird beim Umschalten Besucher↔Admin inkrementiert. Die App-Shell
  /// (HomeScreen) hört darauf und blendet die Admin-Tabs ein/aus.
  final ValueNotifier<int> adminModeRevision = ValueNotifier<int>(0);

  /// Wird bei jeder Änderung der begehbaren Zonen inkrementiert. Die
  /// PositionEngine lädt daraufhin den Snap-Bereich neu.
  final ValueNotifier<int> walkableRevision = ValueNotifier<int>(0);

  /// Async-Factory — `shared_preferences` braucht eine `Future`-Initialisierung.
  /// In `main()` einmal aufrufen und an die Widgets weiterreichen.
  static Future<Storage> open() async {
    final prefs = await SharedPreferences.getInstance();
    return Storage._(prefs);
  }

  // -- Beacon-Placements --------------------------------------------------

  Future<List<BeaconPlacement>> loadBeaconPlacements() async {
    final raw = _prefs.getString(_keyPlacements);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(BeaconPlacement.fromJson)
          .toList();
    } catch (_) {
      // Defekte Persistenz nicht zum App-Crash machen — Default leer.
      return const [];
    }
  }

  Future<void> saveBeaconPlacements(List<BeaconPlacement> placements) async {
    final encoded = jsonEncode(placements.map((p) => p.toJson()).toList());
    await _prefs.setString(_keyPlacements, encoded);
    // Alle Listener (MapScreen etc.) über die Änderung informieren.
    placementsRevision.value++;
  }

  Future<void> upsertPlacement(BeaconPlacement placement) async {
    final current = await loadBeaconPlacements();
    final updated = [
      for (final p in current)
        if (p.beaconId != placement.beaconId) p,
      placement,
    ];
    await saveBeaconPlacements(updated);
  }

  Future<void> removePlacement(int beaconId) async {
    final current = await loadBeaconPlacements();
    final updated = current.where((p) => p.beaconId != beaconId).toList();
    await saveBeaconPlacements(updated);
  }

  /// Übernimmt geteilte Platzierungen vom C2 (Merge nach Beacon-ID, remote
  /// gewinnt). Schreibt einmal → genau ein `placementsRevision`-Bump.
  Future<void> mergePlacements(List<BeaconPlacement> remote) async {
    if (remote.isEmpty) return;
    final byId = {for (final p in await loadBeaconPlacements()) p.beaconId: p};
    for (final r in remote) {
      byId[r.beaconId] = r;
    }
    await saveBeaconPlacements(byId.values.toList());
  }

  // -- Active Floor -------------------------------------------------------

  String? get activeFloorId => _prefs.getString(_keyActiveFloor);

  Future<void> setActiveFloorId(String id) async {
    await _prefs.setString(_keyActiveFloor, id);
  }

  // -- Device-ID ----------------------------------------------------------

  /// Liefert eine pro App-Installation einmalig generierte Geräte-ID.
  /// Wird für die C2-Telemetrie als Sender-Kennung verwendet.
  ///
  /// Bewusst NICHT aus iOS-eindeutigen Werten (IDFV o. ä.) abgeleitet —
  /// Datensparsamkeit (siehe Bericht Kap. 7.4): die ID identifiziert nur
  /// die App-Instanz, nicht das physische Gerät oder den Nutzer.
  Future<String> getOrCreateDeviceId() async {
    var id = _prefs.getString(_keyDeviceId);
    if (id == null || id.isEmpty) {
      id = _generateDeviceId();
      await _prefs.setString(_keyDeviceId, id);
    }
    return id;
  }

  static String _generateDeviceId() {
    // Random.secure() nutzt den CSPRNG des Betriebssystems — verhindert
    // Kollisionen zweier Installationen, die im selben Clock-Tick starten
    // (die ID dient dem C2-Server als eindeutiger Sender-Key).
    final rng = Random.secure();
    final hex = List.generate(
      8,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'app-$hex';
  }

  // -- Fingerprints (RSSI-Kalibrierung, Spec 01) --------------------------

  /// Lädt alle gespeicherten Fingerprints (alle Stockwerke).
  Future<List<Fingerprint>> loadFingerprints() async {
    final raw = _prefs.getString(_keyFingerprints);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(Fingerprint.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Lädt nur die Fingerprints des angegebenen Stockwerks. Harter Floor-Filter
  /// verhindert, dass Fingerprints eines anderen Stocks die Position verfälschen.
  Future<List<Fingerprint>> loadFingerprintsForFloor(String floorId) async {
    final all = await loadFingerprints();
    return all.where((f) => f.floorId == floorId).toList();
  }

  Future<int> countFingerprintsForFloor(String floorId) async {
    final all = await loadFingerprints();
    return all.where((f) => f.floorId == floorId).length;
  }

  Future<void> _writeFingerprints(List<Fingerprint> fps) async {
    final encoded = jsonEncode(fps.map((f) => f.toJson()).toList());
    await _prefs.setString(_keyFingerprints, encoded);
    fingerprintsRevision.value++;
  }

  /// Fügt einen Fingerprint hinzu oder ersetzt einen mit gleicher ID.
  Future<void> saveFingerprint(Fingerprint fp) async {
    final current = await loadFingerprints();
    final updated = [
      for (final f in current)
        if (f.id != fp.id) f,
      fp,
    ];
    await _writeFingerprints(updated);
  }

  Future<void> deleteFingerprint(String id) async {
    final current = await loadFingerprints();
    await _writeFingerprints(current.where((f) => f.id != id).toList());
  }

  Future<void> deleteFingerprintsForFloor(String floorId) async {
    final current = await loadFingerprints();
    await _writeFingerprints(
      current.where((f) => f.floorId != floorId).toList(),
    );
  }

  /// Übernimmt geteilte Fingerprints vom C2 (Merge nach ID, remote gewinnt).
  /// Schreibt einmal → genau ein `fingerprintsRevision`-Bump.
  Future<void> mergeFingerprints(List<Fingerprint> remote) async {
    if (remote.isEmpty) return;
    final byId = {for (final f in await loadFingerprints()) f.id: f};
    for (final r in remote) {
      byId[r.id] = r;
    }
    await _writeFingerprints(byId.values.toList());
  }

  // -- Begehbare Zonen (Snap-to-Walkable, Feature B) ----------------------

  Future<List<WalkableZone>> loadWalkableZones() async {
    final raw = _prefs.getString(_keyWalkableZones);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(WalkableZone.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<WalkableZone>> loadWalkableZonesForFloor(String floorId) async {
    final all = await loadWalkableZones();
    return all.where((z) => z.floorId == floorId).toList();
  }

  Future<void> _writeWalkableZones(List<WalkableZone> zones) async {
    await _prefs.setString(
      _keyWalkableZones,
      jsonEncode(zones.map((z) => z.toJson()).toList()),
    );
    walkableRevision.value++;
  }

  Future<void> saveWalkableZone(WalkableZone zone) async {
    final current = await loadWalkableZones();
    await _writeWalkableZones([
      for (final z in current)
        if (z.id != zone.id) z,
      zone,
    ]);
  }

  Future<void> deleteWalkableZone(String id) async {
    final current = await loadWalkableZones();
    await _writeWalkableZones(current.where((z) => z.id != id).toList());
  }

  Future<void> deleteWalkableZonesForFloor(String floorId) async {
    final current = await loadWalkableZones();
    await _writeWalkableZones(
      current.where((z) => z.floorId != floorId).toList(),
    );
  }

  // -- Admin-Modus & Positions-Strategie ----------------------------------

  /// `true`, wenn der Admin-Modus aktiv ist (zusätzliche Tabs: Setup, Scan,
  /// Kalibrierung). Default `false` → Besucher-Modus (nur Karte).
  bool get adminMode => _prefs.getBool(_keyAdminMode) ?? false;

  Future<void> setAdminMode(bool value) async {
    await _prefs.setBool(_keyAdminMode, value);
    adminModeRevision.value++;
  }

  /// Gewähltes Positions-Verfahren (persistiert über App-Starts).
  PositionStrategy get positionStrategy =>
      PositionStrategy.fromStorageKey(_prefs.getString(_keyStrategy));

  Future<void> setPositionStrategy(PositionStrategy strategy) async {
    await _prefs.setString(_keyStrategy, strategy.storageKey);
  }

  // -- Test-Hooks ---------------------------------------------------------

  /// Nur für Tests / Demo-Reset: alle App-eigenen Keys löschen.
  Future<void> clearAll() async {
    await _prefs.remove(_keyPlacements);
    await _prefs.remove(_keyActiveFloor);
    await _prefs.remove(_keyDeviceId);
    await _prefs.remove(_keyFingerprints);
    await _prefs.remove(_keyAdminMode);
    await _prefs.remove(_keyStrategy);
    await _prefs.remove(_keyWalkableZones);
  }
}
