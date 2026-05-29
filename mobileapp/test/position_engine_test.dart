import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:indoor_nav/models/beacon_placement.dart';
import 'package:indoor_nav/models/position_estimate.dart';
import 'package:indoor_nav/services/ble_scanner.dart';
import 'package:indoor_nav/services/position_engine.dart';
import 'package:indoor_nav/services/storage.dart';

/// Erzeugt eine [PositionEngine] für Solver-Tests ohne BLE-Mock.
Future<PositionEngine> _engine() async {
  SharedPreferences.setMockInitialValues({});
  final storage = await Storage.open();
  return PositionEngine(scanner: BleScanner(), storage: storage);
}

BeaconPlacement _b(int id, double x, double y) => BeaconPlacement(
      beaconId: id,
      floorId: 'test',
      xMeters: x,
      yMeters: y,
    );

void main() {
  group('PositionEngine.solve — Anzahl Beacons', () {
    test('leer → null', () async {
      final eng = await _engine();
      expect(eng.solve(const []), isNull);
    });

    test('1 Beacon → Proximity an Beacon-Position', () async {
      final eng = await _engine();
      final est = eng.solve([
        BeaconDistance(_b(1, 3, 4), 1.5),
      ])!;
      expect(est.method, PositionMethod.proximity);
      expect(est.positionMeters.dx, 3);
      expect(est.positionMeters.dy, 4);
      expect(est.beaconsUsed, 1);
      expect(est.confidence, lessThan(0.3));
    });

    test('2 Beacons → Weighted Centroid (näherer dominiert)', () async {
      final eng = await _engine();
      final est = eng.solve([
        BeaconDistance(_b(1, 0, 0), 1.0),
        BeaconDistance(_b(2, 10, 0), 9.0),
      ])!;
      expect(est.method, PositionMethod.weightedCentroid);
      // Näherer Beacon (B1, d=1) hat 9× mehr Gewicht als B2 (d=9)
      // → Position liegt deutlich näher an B1
      expect(est.positionMeters.dx, lessThan(5.0));
      expect(est.positionMeters.dy, closeTo(0.0, 0.001));
    });
  });

  group('PositionEngine.solve — Trilateration (3+ Beacons)', () {
    test('perfekte Geometrie: drei Beacons im Dreieck, User in der Mitte',
        () async {
      // Beacons an (0,0), (10,0), (5, 8.66) — gleichseitiges Dreieck Seite 10
      // Mittelpunkt = (5, 2.887). Wir setzen distances entsprechend.
      const userX = 5.0;
      const userY = 2.887;

      double dist(double bx, double by) {
        final dx = bx - userX, dy = by - userY;
        return math.sqrt(dx * dx + dy * dy);
      }

      final eng = await _engine();
      final est = eng.solve([
        BeaconDistance(_b(1, 0, 0), dist(0, 0)),
        BeaconDistance(_b(2, 10, 0), dist(10, 0)),
        BeaconDistance(_b(3, 5, 8.66), dist(5, 8.66)),
      ])!;

      expect(est.method, PositionMethod.trilateration);
      expect(est.positionMeters.dx, closeTo(userX, 0.05));
      expect(est.positionMeters.dy, closeTo(userY, 0.05));
      expect(est.residualMeters, closeTo(0, 0.01));
      expect(est.confidence, greaterThan(0.95));
    });

    test('User exakt an einem Beacon → Position dort', () async {
      final eng = await _engine();
      const userX = 0.0;
      const userY = 0.0;
      final est = eng.solve([
        BeaconDistance(_b(1, 0, 0), 0.001), // Beacon = User
        BeaconDistance(_b(2, 10, 0), 10.0),
        BeaconDistance(_b(3, 5, 8.66), 10.0),
      ])!;
      expect(est.positionMeters.dx, closeTo(userX, 0.1));
      expect(est.positionMeters.dy, closeTo(userY, 0.1));
    });

    test(
        'verrauschte Distanzen (±0.5m) → Position innerhalb 1m, '
        'Residuum > 0', () async {
      // Wahre Position (4, 3), Beacons im Quadrat
      // Distanzen mit ±0.5m Rauschen versehen
      const trueX = 4.0;
      const trueY = 3.0;

      double td(double bx, double by) {
        final dx = bx - trueX, dy = by - trueY;
        return math.sqrt(dx * dx + dy * dy);
      }

      final eng = await _engine();
      final est = eng.solve([
        BeaconDistance(_b(1, 0, 0), td(0, 0) + 0.5),
        BeaconDistance(_b(2, 10, 0), td(10, 0) - 0.4),
        BeaconDistance(_b(3, 10, 10), td(10, 10) + 0.3),
        BeaconDistance(_b(4, 0, 10), td(0, 10) - 0.5),
      ])!;

      expect(est.method, PositionMethod.trilateration);
      expect(est.beaconsUsed, 4);
      // Trotz Rauschen sollte Schätzung im Umkreis 1 m liegen
      final dx = est.positionMeters.dx - trueX;
      final dy = est.positionMeters.dy - trueY;
      final error = math.sqrt(dx * dx + dy * dy);
      expect(error, lessThan(1.0),
          reason: 'Positionsfehler $error m bei verrauschten Distanzen');
      expect(est.residualMeters, isNotNull);
      expect(est.residualMeters, greaterThan(0));
    });

    test('kollineare Beacons → null (degenerierte Geometrie)', () async {
      final eng = await _engine();
      final est = eng.solve([
        BeaconDistance(_b(1, 0, 0), 5),
        BeaconDistance(_b(2, 5, 0), 4),
        BeaconDistance(_b(3, 10, 0), 5),
      ]);
      expect(est, isNull,
          reason: 'Bei drei Beacons auf einer Linie kann y nicht '
              'eindeutig bestimmt werden');
    });

    test('Confidence sinkt mit grösserem Residuum', () async {
      final eng = await _engine();
      const ux = 5.0;
      const uy = 3.0;
      double td(double x, double y) {
        final dx = x - ux, dy = y - uy;
        return math.sqrt(dx * dx + dy * dy);
      }

      final konsistent = eng.solve([
        BeaconDistance(_b(1, 0, 0), td(0, 0)),
        BeaconDistance(_b(2, 10, 0), td(10, 0)),
        BeaconDistance(_b(3, 5, 8), td(5, 8)),
      ])!;

      final inkonsistent = eng.solve([
        BeaconDistance(_b(1, 0, 0), 8),
        BeaconDistance(_b(2, 10, 0), 2),
        BeaconDistance(_b(3, 5, 8), 1),
      ])!;

      expect(konsistent.confidence,
          greaterThan(inkonsistent.confidence));
      expect(konsistent.residualMeters!,
          lessThan(inkonsistent.residualMeters!));
    });
  });

  group('PositionEngine.median — RSSI-Glättung', () {
    test('ungerade Anzahl → mittlerer Wert', () async {
      final eng = await _engine();
      expect(eng.median([-60, -55, -70]), -60); // sortiert: -70,-60,-55
    });

    test('gerade Anzahl → Mittel der zwei mittleren', () async {
      final eng = await _engine();
      expect(eng.median([-60, -50, -70, -54]), -57); // -70,-60,-54,-50
    });

    test('robust gegen Ausreisser (Spike verzieht Median nicht)', () async {
      final eng = await _engine();
      // Ein -20-Spike unter stabilen -65ern: Median bleibt bei -65,
      // ein Mittelwert würde deutlich nach oben gezogen.
      final med = eng.median([-65, -64, -20, -66, -65]);
      expect(med, -65);
    });

    test('leer → 0', () async {
      final eng = await _engine();
      expect(eng.median(const []), 0);
    });
  });

  group('PositionEngine.selectReadings — Cutoff + Priorisierung', () {
    test('Beacons jenseits 15 m werden verworfen', () async {
      final eng = await _engine();
      final out = eng.selectReadings([
        BeaconDistance(_b(1, 0, 0), 3),
        BeaconDistance(_b(2, 5, 0), 20), // zu weit → raus
        BeaconDistance(_b(3, 0, 5), 8),
      ]);
      expect(out.map((r) => r.placement.beaconId), [1, 3]);
    });

    test('nach Distanz aufsteigend sortiert (nächste zuerst)', () async {
      final eng = await _engine();
      final out = eng.selectReadings([
        BeaconDistance(_b(1, 0, 0), 9),
        BeaconDistance(_b(2, 5, 0), 2),
        BeaconDistance(_b(3, 0, 5), 5),
      ]);
      expect(out.map((r) => r.placement.beaconId), [2, 3, 1]);
    });

    test('auf nächste 5 begrenzt (maxBeaconsForFix)', () async {
      final eng = await _engine();
      final out = eng.selectReadings([
        for (var i = 1; i <= 8; i++) BeaconDistance(_b(i, 0, 0), i.toDouble()),
      ]);
      expect(out.length, 5);
      expect(out.map((r) => r.placement.beaconId), [1, 2, 3, 4, 5]);
    });

    test('genau am 15-m-Grenzwert wird noch akzeptiert', () async {
      final eng = await _engine();
      final out = eng.selectReadings([
        BeaconDistance(_b(1, 0, 0), 15.0),
      ]);
      expect(out.length, 1);
    });
  });
}
