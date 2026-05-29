import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav/models/fingerprint.dart';

void main() {
  group('Fingerprint JSON', () {
    test('Round-Trip erhält alle Felder inkl. int-Beacon-Keys', () {
      final fp = Fingerprint(
        id: 'fp-1',
        floorId: 'hslu_3',
        xMeters: 12.5,
        yMeters: 4.0,
        rssiByBeaconId: const {1: -55.0, 12: -68.5},
        sampleCount: 22,
        capturedAt: DateTime.parse('2026-05-29T10:00:00.000'),
      );

      final back = Fingerprint.fromJson(fp.toJson());

      expect(back.id, 'fp-1');
      expect(back.floorId, 'hslu_3');
      expect(back.xMeters, 12.5);
      expect(back.yMeters, 4.0);
      // Beacon-IDs müssen wieder int sein (JSON-Keys sind String).
      expect(back.rssiByBeaconId[1], -55.0);
      expect(back.rssiByBeaconId[12], -68.5);
      expect(back.sampleCount, 22);
      expect(back.capturedAt, DateTime.parse('2026-05-29T10:00:00.000'));
    });
  });

  group('FingerprintAccumulator', () {
    test('Median über Samples korrekt', () {
      final acc = FingerprintAccumulator()
        ..addSample(1, -50)
        ..addSample(1, -60)
        ..addSample(1, -55);
      expect(acc.currentAverages[1], closeTo(-55.0, 1e-9));
      expect(acc.totalSamples, 3);
      expect(acc.beaconCount, 1);
      expect(acc.sampleCounts[1], 3);
    });

    test('Median ist robust gegen einen Multipath-Spike', () {
      // Vier solide −70-Messungen + ein Ausreisser −20.
      // Median = −70 (Spike ignoriert), Mittelwert wäre −60 (verzogen).
      final acc = FingerprintAccumulator()
        ..addSample(7, -70)
        ..addSample(7, -70)
        ..addSample(7, -70)
        ..addSample(7, -70)
        ..addSample(7, -20);
      expect(acc.currentAverages[7], closeTo(-70.0, 1e-9));

      // Auch im gespeicherten Fingerprint landet der robuste Wert.
      acc
        ..addSample(8, -65)
        ..addSample(8, -65)
        ..addSample(8, -65);
      final fp = acc.build(
        id: 'x',
        floorId: 'h',
        xMeters: 0,
        yMeters: 0,
        capturedAt: DateTime(2026),
      );
      expect(fp, isNotNull);
      expect(fp!.rssiByBeaconId[7], closeTo(-70.0, 1e-9));
    });

    test('Beacon mit <minSamples Messungen wird beim build verworfen', () {
      final acc = FingerprintAccumulator()
        ..addSample(1, -50)
        ..addSample(1, -50)
        ..addSample(1, -50) // Beacon 1: 3 → bleibt
        ..addSample(2, -70)
        ..addSample(2, -70) // Beacon 2: 2 → verworfen
        ..addSample(3, -60)
        ..addSample(3, -60)
        ..addSample(3, -60); // Beacon 3: 3 → bleibt

      final fp = acc.build(
        id: 'x',
        floorId: 'h',
        xMeters: 0,
        yMeters: 0,
        capturedAt: DateTime(2026),
      );

      expect(fp, isNotNull);
      expect(fp!.rssiByBeaconId.keys, unorderedEquals(<int>[1, 3]));
    });

    test('weniger als minBeacons gültige Beacons → build liefert null', () {
      final acc = FingerprintAccumulator()
        ..addSample(1, -50)
        ..addSample(1, -50)
        ..addSample(1, -50); // nur 1 gültiger Beacon

      final fp = acc.build(
        id: 'x',
        floorId: 'h',
        xMeters: 0,
        yMeters: 0,
        capturedAt: DateTime(2026),
      );

      expect(fp, isNull);
    });

    test('sampleCount zählt nur die übernommenen Beacons', () {
      final acc = FingerprintAccumulator()
        ..addSample(1, -50)
        ..addSample(1, -50)
        ..addSample(1, -50) // 3 übernommen
        ..addSample(2, -70)
        ..addSample(2, -70)
        ..addSample(2, -70)
        ..addSample(2, -70) // 4 übernommen
        ..addSample(3, -60); // 1 verworfen

      final fp = acc.build(
        id: 'x',
        floorId: 'h',
        xMeters: 0,
        yMeters: 0,
        capturedAt: DateTime(2026),
      );

      expect(fp, isNotNull);
      expect(fp!.sampleCount, 7); // 3 + 4, Beacon 3 nicht gezählt
      expect(fp.rssiByBeaconId.keys, unorderedEquals(<int>[1, 2]));
    });
  });
}
