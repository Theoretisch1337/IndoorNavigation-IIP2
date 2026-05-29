import 'package:flutter/painting.dart' show Offset, Rect;

import '../models/floor_plan.dart';
import '../models/walkable_zone.dart';

/// Begehbare Flächen + Snap-to-Path (Spec 04).
///
/// Die begehbare Fläche eines Stockwerks ist:
/// - die vom Admin **gezeichneten Zonen** (Feature B), falls vorhanden,
/// - sonst die **Räume** des Grundrisses (Feature A, Fallback),
/// jeweils **minus** der Lufträume ([FloorPlan.voids], z. B. Atrium).
///
/// [snapToWalkable] projiziert eine rohe Position auf den nächsten begehbaren
/// Punkt, damit der Marker nie in einer Wand oder im Luftraum landet.

/// Begehbare Rechtecke: gezeichnete Zonen (falls vorhanden), sonst die Räume.
List<Rect> walkableRectsFor(FloorPlan floor, List<WalkableZone> zones) {
  if (zones.isNotEmpty) return [for (final z in zones) z.bounds];
  return [for (final r in floor.rooms) r.bounds];
}

/// Klemmt einen Punkt in ein Rechteck (= nächster Punkt im/auf dem Rechteck).
Offset _clampToRect(Offset p, Rect r) => Offset(
      p.dx.clamp(r.left, r.right),
      p.dy.clamp(r.top, r.bottom),
    );

/// Schiebt einen Punkt, der in einem Luftraum liegt, an dessen nächsten Rand
/// (knapp ausserhalb), innerhalb von [within] geklemmt. Deckt das Atrium-
/// Szenario ab (Luftraum liegt innerhalb des begehbaren Rechtecks).
Offset _pushOutOfVoids(Offset p, List<Rect> voids, Rect within) {
  const eps = 0.05;
  for (final v in voids) {
    if (!v.contains(p)) continue;
    final toLeft = p.dx - v.left;
    final toRight = v.right - p.dx;
    final toTop = p.dy - v.top;
    final toBottom = v.bottom - p.dy;
    final nearest = [toLeft, toRight, toTop, toBottom].reduce((a, b) => a < b ? a : b);

    final Offset moved;
    if (nearest == toLeft) {
      moved = Offset(v.left - eps, p.dy);
    } else if (nearest == toRight) {
      moved = Offset(v.right + eps, p.dy);
    } else if (nearest == toTop) {
      moved = Offset(p.dx, v.top - eps);
    } else {
      moved = Offset(p.dx, v.bottom + eps);
    }
    return _clampToRect(moved, within);
  }
  return p;
}

/// **Snap-to-Walkable**: projiziert [p] auf den nächsten begehbaren Punkt.
///
/// - Liegt [p] bereits begehbar (in einem Rechteck, in keinem Luftraum),
///   bleibt es unverändert.
/// - Gibt es keine begehbaren Rechtecke (kein Modell), ist Snap ein No-Op.
Offset snapToWalkable(Offset p, List<Rect> walkable, List<Rect> voids) {
  if (walkable.isEmpty) return p;

  bool isWalkable(Offset q) =>
      walkable.any((r) => r.contains(q)) && !voids.any((v) => v.contains(q));

  if (isWalkable(p)) return p;

  Offset? best;
  var bestDist = double.infinity;
  for (final r in walkable) {
    final candidate = _pushOutOfVoids(_clampToRect(p, r), voids, r);
    final d = (candidate - p).distanceSquared;
    if (d < bestDist) {
      bestDist = d;
      best = candidate;
    }
  }
  return best ?? p;
}
