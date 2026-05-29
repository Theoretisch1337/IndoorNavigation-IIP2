import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:indoor_nav/models/beacon_placement.dart';
import 'package:indoor_nav/models/fingerprint.dart';
import 'package:indoor_nav/models/position_strategy.dart';
import 'package:indoor_nav/services/storage.dart';

void main() {
  setUp(() {
    // Reset Shared-Preferences zwischen Tests — sonst leaken sie.
    SharedPreferences.setMockInitialValues({});
  });

  group('Storage', () {
    test('liefert leere Liste wenn nichts gespeichert', () async {
      final s = await Storage.open();
      expect(await s.loadBeaconPlacements(), isEmpty);
    });

    test('Round-Trip: speichern und wieder laden', () async {
      final s = await Storage.open();
      final placements = [
        const BeaconPlacement(
          beaconId: 1,
          floorId: 'hslu_3',
          xMeters: 2.5,
          yMeters: 4.0,
          txPowerOverride: -61,
          label: 'Eingang',
        ),
        const BeaconPlacement(
          beaconId: 2,
          floorId: 'hslu_3',
          xMeters: 10.0,
          yMeters: 4.0,
        ),
      ];

      await s.saveBeaconPlacements(placements);
      final loaded = await s.loadBeaconPlacements();

      expect(loaded.length, 2);
      expect(loaded[0].beaconId, 1);
      expect(loaded[0].xMeters, 2.5);
      expect(loaded[0].txPowerOverride, -61);
      expect(loaded[0].label, 'Eingang');
      expect(loaded[1].txPowerOverride, isNull);
    });

    test('upsertPlacement überschreibt vorhandene ID', () async {
      final s = await Storage.open();
      await s.upsertPlacement(
        const BeaconPlacement(
          beaconId: 1,
          floorId: 'hslu_3',
          xMeters: 1.0,
          yMeters: 1.0,
        ),
      );
      await s.upsertPlacement(
        const BeaconPlacement(
          beaconId: 1,
          floorId: 'hslu_3',
          xMeters: 5.0,
          yMeters: 5.0,
        ),
      );

      final loaded = await s.loadBeaconPlacements();
      expect(loaded, hasLength(1));
      expect(loaded.first.xMeters, 5.0);
    });

    test('removePlacement entfernt nur den gewünschten Beacon', () async {
      final s = await Storage.open();
      await s.saveBeaconPlacements(const [
        BeaconPlacement(
            beaconId: 1, floorId: 'h', xMeters: 0, yMeters: 0),
        BeaconPlacement(
            beaconId: 2, floorId: 'h', xMeters: 0, yMeters: 0),
        BeaconPlacement(
            beaconId: 3, floorId: 'h', xMeters: 0, yMeters: 0),
      ]);

      await s.removePlacement(2);
      final loaded = await s.loadBeaconPlacements();

      expect(loaded.map((p) => p.beaconId), unorderedEquals([1, 3]));
    });

    test('defekte JSON-Werte führen zu leerer Liste statt Crash', () async {
      SharedPreferences.setMockInitialValues({
        'beacon_placements_v1': '{not-json',
      });
      final s = await Storage.open();
      expect(await s.loadBeaconPlacements(), isEmpty);
    });

    test('activeFloorId speichert und liest', () async {
      final s = await Storage.open();
      expect(s.activeFloorId, isNull);
      await s.setActiveFloorId('hslu_3');
      // Neu öffnen, um echtes Re-Read zu simulieren
      final s2 = await Storage.open();
      expect(s2.activeFloorId, 'hslu_3');
    });
  });

  group('Storage — Fingerprints & Einstellungen', () {
    Fingerprint fp(String id, String floor) => Fingerprint(
          id: id,
          floorId: floor,
          xMeters: 1,
          yMeters: 2,
          rssiByBeaconId: const {1: -55.0},
          sampleCount: 5,
          capturedAt: DateTime(2026),
        );

    test('Fingerprint Round-Trip + Floor-Filter', () async {
      final s = await Storage.open();
      await s.saveFingerprint(fp('a', 'hslu_3'));
      await s.saveFingerprint(fp('b', 'home'));

      expect((await s.loadFingerprints()).length, 2);
      final f3 = await s.loadFingerprintsForFloor('hslu_3');
      expect(f3, hasLength(1));
      expect(f3.first.id, 'a');
      expect(await s.countFingerprintsForFloor('hslu_3'), 1);
    });

    test('saveFingerprint überschreibt gleiche ID', () async {
      final s = await Storage.open();
      await s.saveFingerprint(fp('a', 'h'));
      await s.saveFingerprint(
        Fingerprint(
          id: 'a',
          floorId: 'h',
          xMeters: 9,
          yMeters: 9,
          rssiByBeaconId: const {1: -40.0},
          sampleCount: 8,
          capturedAt: DateTime(2026),
        ),
      );
      final all = await s.loadFingerprints();
      expect(all, hasLength(1));
      expect(all.first.xMeters, 9);
    });

    test('deleteFingerprintsForFloor entfernt nur den Ziel-Floor', () async {
      final s = await Storage.open();
      await s.saveFingerprint(fp('a', 'hslu_3'));
      await s.saveFingerprint(fp('b', 'home'));
      await s.deleteFingerprintsForFloor('hslu_3');
      final all = await s.loadFingerprints();
      expect(all, hasLength(1));
      expect(all.first.floorId, 'home');
    });

    test('adminMode: Default false, persistiert', () async {
      final s = await Storage.open();
      expect(s.adminMode, isFalse);
      await s.setAdminMode(true);
      final s2 = await Storage.open();
      expect(s2.adminMode, isTrue);
    });

    test('positionStrategy: Default Trilateration, persistiert', () async {
      final s = await Storage.open();
      expect(s.positionStrategy, PositionStrategy.trilateration);
      await s.setPositionStrategy(PositionStrategy.hybrid);
      final s2 = await Storage.open();
      expect(s2.positionStrategy, PositionStrategy.hybrid);
    });
  });
}
