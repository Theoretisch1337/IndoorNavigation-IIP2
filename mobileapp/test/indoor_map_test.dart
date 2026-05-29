import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/models/beacon.dart';
import 'package:indoor_nav/models/beacon_placement.dart';
import 'package:indoor_nav/models/floor_plan.dart';
import 'package:indoor_nav/widgets/indoor_map.dart';

/// Reproduziert den „graue Karte in der Kalibrierung"-Bug: sobald nach einem
/// Fingerprint die Karte neu baut, zeigt der Release-Build eine graue
/// RenderErrorBox -> eine gefangene Build-Exception im IndoorMap-Subtree.
/// testWidgets schlaegt bei einer ungefangenen Exception automatisch fehl.
void main() {
  testWidgets('IndoorMap: nur Fingerprint-Punkte', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: IndoorMap(
            floor: hsluFloor3,
            fingerprintPoints: [Offset(10, 10), Offset(20, 15)],
            showDistanceRings: false,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(IndoorMap), findsOneWidget);
  });

  testWidgets('IndoorMap: voller Kalibrierungs-Kontext (Placements + Scans + Fingerprints)',
      (tester) async {
    final scans = <int, BeaconScan>{
      1: BeaconScan(
        deviceId: 'd1',
        name: 'INNAV-1',
        rssi: -65,
        beaconId: 1,
        batteryPercent: 100,
        sequenceNum: 1,
        txPower: -59,
        lastSeen: DateTime(2026, 1, 1),
      ),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IndoorMap(
            floor: hsluFloor3,
            placements: const [
              BeaconPlacement(
                  beaconId: 1, floorId: 'hslu_3', xMeters: 5, yMeters: 5),
              BeaconPlacement(
                  beaconId: 2, floorId: 'hslu_3', xMeters: 60, yMeters: 40),
            ],
            beaconScans: scans,
            fingerprintPoints: const [Offset(10, 10), Offset(20, 15)],
            showDistanceRings: false,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(IndoorMap), findsOneWidget);
  });
}
