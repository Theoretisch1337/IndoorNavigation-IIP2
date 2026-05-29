import 'package:flutter/painting.dart' show Offset, Rect;
import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/models/floor_plan.dart';
import 'package:indoor_nav/models/walkable_zone.dart';
import 'package:indoor_nav/services/walkable.dart';

void main() {
  group('walkableRectsFor', () {
    test('ohne Zonen → Räume des Grundrisses (Fallback A)', () {
      final rects = walkableRectsFor(homeTestFloor, const []);
      expect(rects, hasLength(homeTestFloor.rooms.length));
      expect(rects.first, homeTestFloor.rooms.first.bounds);
    });

    test('mit Zonen → die gezeichneten Zonen (B gewinnt)', () {
      final zones = [
        const WalkableZone(
          id: 'z1',
          floorId: 'home',
          bounds: Rect.fromLTWH(1, 1, 2, 2),
        ),
      ];
      final rects = walkableRectsFor(homeTestFloor, zones);
      expect(rects, hasLength(1));
      expect(rects.first, const Rect.fromLTWH(1, 1, 2, 2));
    });
  });

  group('snapToWalkable', () {
    const room = Rect.fromLTWH(0, 0, 10, 10);
    const voidRect = Rect.fromLTWH(3, 3, 4, 4); // Luftraum im Raum

    test('Punkt bereits begehbar → unverändert', () {
      expect(snapToWalkable(const Offset(1, 1), const [room], const []),
          const Offset(1, 1));
    });

    test('Punkt ausserhalb → auf den nächsten Rechteck-Rand geklemmt', () {
      final r = snapToWalkable(const Offset(15, 5), const [room], const []);
      expect(r.dx, closeTo(10, 1e-9));
      expect(r.dy, closeTo(5, 1e-9));
    });

    test('Punkt im Luftraum → herausgeschoben (begehbar danach)', () {
      final r = snapToWalkable(const Offset(5, 5), const [room], const [voidRect]);
      expect(room.contains(r), isTrue);
      expect(voidRect.contains(r), isFalse);
    });

    test('keine begehbaren Rechtecke → No-Op', () {
      expect(snapToWalkable(const Offset(5, 5), const [], const []),
          const Offset(5, 5));
    });

    test('mehrere Rechtecke → nächstes gewinnt', () {
      const left = Rect.fromLTWH(0, 0, 4, 4);
      const right = Rect.fromLTWH(10, 0, 4, 4);
      // (9, 2) liegt näher am rechten Rechteck → geklemmt auf dessen linke Kante.
      final r = snapToWalkable(const Offset(9, 2), const [left, right], const []);
      expect(r.dx, closeTo(10, 1e-9));
      expect(r.dy, closeTo(2, 1e-9));
    });
  });
}
