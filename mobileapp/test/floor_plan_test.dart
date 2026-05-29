import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/models/floor_plan.dart';

void main() {
  group('FloorPlan', () {
    test('boundsMeters entspricht width/height', () {
      expect(homeTestFloor.boundsMeters, const Rect.fromLTWH(0, 0, 4.0, 3.0));
    });

    test('roomAt findet den richtigen Raum (HSLU 301)', () {
      // Raum 301 liegt bei (2..12, 0..12) im neuen Layout
      final room = hsluFloor3.roomAt(5, 5);
      expect(room?.id, '301');
    });

    test('roomAt findet die Erschliessung (Korridor 300)', () {
      // Raum 300 ist die zentrale Erschliessung (13..58, 15..27)
      final room = hsluFloor3.roomAt(36, 21);
      expect(room?.id, '300');
    });

    test('roomAt gibt null ausserhalb aller Räume zurück', () {
      // Ausserhalb des Layouts
      final room = hsluFloor3.roomAt(75, 50);
      expect(room, isNull);
    });

    test('floorById findet HSLU-Stock-3 per ID', () {
      expect(floorById('hslu_3').id, 'hslu_3');
    });

    test('floorById fällt auf ersten Floor zurück bei unbekannter ID', () {
      expect(floorById('unbekannt'), availableFloors.first);
    });

    test('floorById toleriert null', () {
      expect(floorById(null), availableFloors.first);
    });
  });
}
