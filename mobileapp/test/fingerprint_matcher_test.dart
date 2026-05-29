import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:indoor_nav/models/fingerprint.dart';
import 'package:indoor_nav/models/position_estimate.dart';
import 'package:indoor_nav/services/ble_scanner.dart';
import 'package:indoor_nav/services/position_engine.dart';
import 'package:indoor_nav/services/storage.dart';

/// Testet `PositionEngine.kNNMatch` isoliert. Die Engine wird mit Mock-Storage
/// und einem nicht gestarteten Scanner konstruiert — kNNMatch ist rein
/// rechnend und hängt nicht vom BLE-Stack ab.
void main() {
  late Storage storage;
  late BleScanner scanner;
  late PositionEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open();
    scanner = BleScanner();
    engine = PositionEngine(scanner: scanner, storage: storage);
  });

  tearDown(() async {
    await engine.dispose();
    await scanner.dispose();
  });

  Fingerprint fp(String id, double x, double y, Map<int, double> rssi) =>
      Fingerprint(
        id: id,
        floorId: 'h',
        xMeters: x,
        yMeters: y,
        rssiByBeaconId: rssi,
        sampleCount: 10,
        capturedAt: DateTime(2026),
      );

  // Zwei Fingerprints links (A) und rechts (B), gegenläufige Signaturen.
  final a = fp('A', 0, 0, const {1: -50, 2: -60});
  final b = fp('B', 10, 0, const {1: -70, 2: -50});

  test('exakter Treffer → genau dessen Position', () {
    final est = engine.kNNMatch(const {1: -50, 2: -60}, [a, b]);
    expect(est, isNotNull);
    expect(est!.positionMeters.dx, closeTo(0, 0.01));
    expect(est.positionMeters.dy, closeTo(0, 0.01));
    expect(est.method, PositionMethod.fingerprinting);
  });

  test('mittige Signatur → gewichtetes Mittel auf Verbindungslinie', () {
    final est = engine.kNNMatch(const {1: -60, 2: -55}, [a, b]);
    expect(est, isNotNull);
    expect(est!.positionMeters.dx, closeTo(5, 0.5));
    expect(est.positionMeters.dy, closeTo(0, 0.01));
  });

  test('nächstes Fingerprint dominiert', () {
    final est = engine.kNNMatch(const {1: -52, 2: -58}, [a, b]); // nahe A
    expect(est, isNotNull);
    expect(est!.positionMeters.dx, lessThan(2.5));
  });

  test('Beacon fehlt im Fingerprint → ignoriert, andere zählen', () {
    final c = fp('C', 3, 3, const {1: -50}); // nur Beacon 1
    // Aktuelle Signatur hat zusätzlich Beacon 2 → für C ignoriert.
    final est = engine.kNNMatch(
      const {1: -50, 2: -99},
      [c],
      minCommonBeacons: 1,
    );
    expect(est, isNotNull);
    expect(est!.positionMeters.dx, closeTo(3, 0.01));
    expect(est.positionMeters.dy, closeTo(3, 0.01));
  });

  test('zu wenige gemeinsame Beacons → Fingerprint übersprungen → null', () {
    // A hat Beacon 1+2, Signatur nur Beacon 2 → 1 gemeinsam < minCommon (2).
    final est = engine.kNNMatch(const {2: -50}, [a]);
    expect(est, isNull);
  });

  test('keine Fingerprints oder leere Signatur → null', () {
    expect(engine.kNNMatch(const {1: -50, 2: -60}, const []), isNull);
    expect(engine.kNNMatch(const {}, [a, b]), isNull);
  });

  test('k begrenzt die Nachbarn (k=1 → nur das nächste)', () {
    final est = engine.kNNMatch(const {1: -50, 2: -60}, [a, b], k: 1);
    expect(est, isNotNull);
    expect(est!.positionMeters.dx, closeTo(0, 0.01)); // nur A
  });
}
