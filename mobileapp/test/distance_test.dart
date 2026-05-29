import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/models/beacon.dart';

/// Unit-Tests für das Pfadverlust-Modell.
///
/// Dient gleichzeitig als Beleg für Bericht Kap. 6 (Validation):
/// die Distanzformel ist deterministisch, monoton fallend in RSSI und
/// liefert plausible Werte für typische Indoor-Bereiche (0.5 m – 20 m).
void main() {
  group('BeaconScan.distanceFromRssi', () {
    test('RSSI gleich TX-Power → exakt 1 m', () {
      final d = BeaconScan.distanceFromRssi(rssi: -59, txPower: -59);
      expect(d, closeTo(1.0, 0.001));
    });

    test('RSSI = TX-Power − 10 dB → 10^(1/2.5) ≈ 2.51 m bei n=2.5', () {
      final d = BeaconScan.distanceFromRssi(rssi: -69, txPower: -59);
      expect(d, closeTo(2.512, 0.01));
    });

    test('schwächeres Signal liefert grössere Distanz (Monotonie)', () {
      final near = BeaconScan.distanceFromRssi(rssi: -55, txPower: -59);
      final far = BeaconScan.distanceFromRssi(rssi: -85, txPower: -59);
      expect(near, lessThan(far));
    });

    test('Pfadverlust-Exponent verändert das Ergebnis erwartet', () {
      final freiFeld = BeaconScan.distanceFromRssi(
        rssi: -79,
        txPower: -59,
        pathLossExponent: 2.0,
      );
      final dichteUmgebung = BeaconScan.distanceFromRssi(
        rssi: -79,
        txPower: -59,
        pathLossExponent: 4.0,
      );
      // Bei kleinerem n wird die gleiche Dämpfung als grössere Distanz
      // interpretiert → freiFeld > dichteUmgebung.
      expect(freiFeld, greaterThan(dichteUmgebung));
      expect(freiFeld, closeTo(10.0, 0.01));
      expect(dichteUmgebung, closeTo(3.162, 0.01));
    });

    test('Indoor-Sanity-Check: RSSI -60..-90 ergibt 1..20 m', () {
      for (var rssi = -60; rssi >= -90; rssi -= 5) {
        final d = BeaconScan.distanceFromRssi(rssi: rssi, txPower: -59);
        expect(d, inInclusiveRange(0.5, 20.0),
            reason: 'Distanz für RSSI $rssi war $d m');
      }
    });
  });
}
