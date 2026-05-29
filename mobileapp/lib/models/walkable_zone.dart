import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Rect;

/// Ein vom Admin gezeichnetes **begehbares Rechteck** auf einem Stockwerk
/// (Feature B). Sind für einen Floor Zonen vorhanden, definieren sie die
/// begehbare Fläche; sonst fällt die Snap-Logik auf die Räume zurück (A).
///
/// Koordinaten in **Metern** (Stockwerk-System, Ursprung oben links) — gleiche
/// Konvention wie [Room]/[FloorVoid] in `floor_plan.dart`.
@immutable
class WalkableZone {
  const WalkableZone({
    required this.id,
    required this.floorId,
    required this.bounds,
  });

  final String id;
  final String floorId;
  final Rect bounds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'floorId': floorId,
        'l': bounds.left,
        't': bounds.top,
        'w': bounds.width,
        'h': bounds.height,
      };

  factory WalkableZone.fromJson(Map<String, dynamic> json) => WalkableZone(
        id: json['id'] as String,
        floorId: json['floorId'] as String,
        bounds: Rect.fromLTWH(
          (json['l'] as num).toDouble(),
          (json['t'] as num).toDouble(),
          (json['w'] as num).toDouble(),
          (json['h'] as num).toDouble(),
        ),
      );
}
