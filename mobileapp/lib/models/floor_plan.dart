import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Vektorbasierte Beschreibung eines Stockwerks.
///
/// Koordinaten-System: **Meter**, Ursprung **oben links** (X nach rechts,
/// Y nach unten). Diese Konvention spiegelt das übliche Screen-Layout und
/// vermeidet Y-Achsen-Flip beim Rendern.
///
/// Ein [FloorPlan] ist immutable. Für die Konvertierung Meter↔Pixel ist
/// `widgets/indoor_map.dart` zuständig (Scale-Faktor nach Container-Grösse).
@immutable
class FloorPlan {
  const FloorPlan({
    required this.id,
    required this.displayName,
    required this.widthMeters,
    required this.heightMeters,
    required this.rooms,
    this.pois = const [],
    this.voids = const [],
    this.backgroundAsset,
  });

  final String id;
  final String displayName;
  final double widthMeters;
  final double heightMeters;
  final List<Room> rooms;
  final List<PointOfInterest> pois;

  /// Optionaler Asset-Pfad zu einem echten Grundriss-Bild. Wenn gesetzt,
  /// rendert die Karte dieses Bild als Hintergrund-Layer (statt der
  /// schematischen Vektor-Räume) — die Räume bleiben im Modell für
  /// `roomAt`/Navigation erhalten. Das Bild wird über die
  /// `widthMeters × heightMeters`-Bounds gelegt.
  final String? backgroundAsset;

  /// Nicht-begehbare Bereiche (z. B. Atrium / Luftraum über dem darunter-
  /// liegenden Stockwerk). Werden in der Karte als „Loch" dargestellt und
  /// sind für Phase-2-Navigation aus der begehbaren Fläche ausgenommen
  /// (Snap-to-Path projiziert die Position aus diesen Bereichen heraus).
  final List<FloorVoid> voids;

  /// `true`, wenn die Meter-Koordinate in einem nicht-begehbaren Bereich liegt.
  bool isVoid(double xMeters, double yMeters) {
    for (final v in voids) {
      if (v.bounds.contains(Offset(xMeters, yMeters))) return true;
    }
    return false;
  }

  /// Bounding-Box des gesamten Stockwerks in Metern.
  Rect get boundsMeters => Rect.fromLTWH(0, 0, widthMeters, heightMeters);

  /// Findet den Raum, der eine gegebene Meter-Koordinate enthält.
  /// Wird vom Snap-to-Room / POI-Lookup verwendet.
  Room? roomAt(double xMeters, double yMeters) {
    for (final room in rooms) {
      if (room.bounds.contains(Offset(xMeters, yMeters))) return room;
    }
    return null;
  }
}

/// Funktionstyp eines Raums — steuert die farbliche Darstellung in der
/// IndoorMap und erlaubt spätere Logik (z. B. „nur Unterrichtsräume als
/// Navigationsziel").
enum RoomType {
  unterricht,
  innovation,
  werkstatt,
  aufenthalt,
  korridor,
  treppe,
  lift,
  wc,
  service,
}

/// Rechteckiger Raum auf einem Stockwerk.
///
/// [bounds] ist in **Metern** (Stockwerk-Koordinaten), nicht in Pixeln.
@immutable
class Room {
  const Room({
    required this.id,
    required this.label,
    required this.bounds,
    this.type = RoomType.unterricht,
  });

  final String id;
  final String label;
  final Rect bounds;
  final RoomType type;

  Offset get centerMeters => bounds.center;

  @override
  String toString() => 'Room($id "$label" @ $bounds)';
}

/// Nicht-begehbarer Bereich (Atrium / Luftraum / Schacht).
@immutable
class FloorVoid {
  const FloorVoid({required this.label, required this.bounds});
  final String label;
  final Rect bounds;
}

/// Punkt-Interesse-Marker (Lift, WC, Mensa, Treppe, …).
///
/// Wird über dem Raum-Layer gerendert.
@immutable
class PointOfInterest {
  const PointOfInterest({
    required this.id,
    required this.label,
    required this.positionMeters,
    required this.icon,
  });

  final String id;
  final String label;
  final Offset positionMeters;
  final IconData icon;
}

// ---------------------------------------------------------------------------
//  Sample Floor Plans
// ---------------------------------------------------------------------------
//
// Diese Layouts dienen Demo + lokalem Testing. Die HSLU-Stockwerk-3-Variante
// ist ein vereinfachter Platzhalter — sobald der Grundriss vorliegt, werden
// die Raum-Koordinaten direkt aus dem Plan übertragen.

/// Leeres Test-Layout („Blank Canvas") für lokales Setup zuhause (z. B.
/// Wohnzimmer). Ein einzelner 4×3m-Raum, 3 Beacons in den Ecken sind
/// realistisch.
const FloorPlan homeTestFloor = FloorPlan(
  id: 'home',
  displayName: 'Blank Canvas',
  widthMeters: 4.0,
  heightMeters: 3.0,
  rooms: [
    Room(
      id: 'test.01',
      label: 'Testraum',
      bounds: Rect.fromLTWH(0, 0, 4.0, 3.0),
    ),
  ],
);

/// HSLU-Campus Rotkreuz — Stockwerk 3 (Suurstoffi/Pilatus).
///
/// Abgeleitet aus dem Architektur-Grundriss (PNG, vom User erhalten am
/// 28.05.2026, Quelle HSLU-Bauplan). Räume sind mit ihren offiziellen
/// HSLU-Nummern modelliert (300–337). Dimensionen sind aus den im Plan
/// angegebenen BF-Werten (Bodenflächen in m²) abgeleitet, mit dem
/// zentralen Korridor (Raum 300 „Erschliessung", BF 367.15 m²) als
/// Massstabs-Anker.
///
/// Koordinaten-System: Meter, Ursprung oben-links (entspricht der
/// Plan-Orientierung im Original-PNG: Norden ≈ oben).
///
/// Gebäude-Bounding-Box: 66 × 42 m. Layout grundriss-getreu aus dem
/// HSLU-Bauplan rekonstruiert: drei horizontale Raumbänder (oben / Korridor /
/// unten) mit zwei seitlichen Treppenhäusern und zentralem Korridor 300.
/// Raum-Reihenfolge und relative Grössen entsprechen dem Original-Grundriss;
/// die Treppenhaus-Cluster (335/336/337 West, 315/316/317 Ost) flankieren den
/// Korridor symmetrisch.
const FloorPlan hsluFloor3 = FloorPlan(
  id: 'hslu_3',
  displayName: 'HSLU Suurstoffi, Stock 3',
  widthMeters: 66.0,
  // Höhe = Breite × Bild-Seitenverhältnis (1652/2332) → keine Verzerrung
  // des Grundriss-Bilds (assets/floor_plans/hslu_stock3.png, 2332×1652 px).
  heightMeters: 46.75,
  backgroundAsset: 'assets/floor_plans/hslu_stock3.png',
  rooms: [
    // ══════ Oberes Raumband (Norden, y 1–12) ══════
    Room(id: '301', label: '301', bounds: Rect.fromLTWH(1, 1, 13, 11)),
    Room(id: '302', label: '302 Werkstatt', bounds: Rect.fromLTWH(14, 1, 8, 11), type: RoomType.werkstatt),
    Room(id: '303', label: '303 Innovation Space', bounds: Rect.fromLTWH(22, 1, 13, 11), type: RoomType.innovation),
    Room(id: '304', label: '304', bounds: Rect.fromLTWH(35, 1, 11, 11)),
    Room(id: '309', label: '309', bounds: Rect.fromLTWH(46, 1, 8, 11)),
    Room(id: '310', label: '310', bounds: Rect.fromLTWH(54, 1, 11, 5.5)),
    Room(id: '311', label: '311', bounds: Rect.fromLTWH(54, 6.5, 11, 5.5)),

    // Service-Cluster zwischen 309 und Korridor (kleine Boxen)
    Room(id: '305', label: '305', bounds: Rect.fromLTWH(46, 12.2, 2.7, 2.6), type: RoomType.service),
    Room(id: '306', label: '306', bounds: Rect.fromLTWH(48.7, 12.2, 2.6, 2.6), type: RoomType.service),
    Room(id: '307', label: '307', bounds: Rect.fromLTWH(51.3, 12.2, 2.7, 2.6), type: RoomType.service),

    // ══════ Treppenhaus West (links der Korridor-Achse) ══════
    Room(id: '336', label: '336', bounds: Rect.fromLTWH(1, 13, 4, 2.5), type: RoomType.service),
    Room(id: '335', label: '335 Treppe', bounds: Rect.fromLTWH(1, 15.5, 9, 7), type: RoomType.treppe),
    Room(id: '337', label: '337 WC', bounds: Rect.fromLTWH(1, 22.5, 7, 4.5), type: RoomType.wc),

    // ══════ Treppenhaus Ost (rechts der Korridor-Achse) ══════
    Room(id: '316', label: '316', bounds: Rect.fromLTWH(61, 13, 4, 2.5), type: RoomType.service),
    Room(id: '315', label: '315 Treppe', bounds: Rect.fromLTWH(56, 15.5, 9, 7), type: RoomType.treppe),
    Room(id: '317', label: '317 WC', bounds: Rect.fromLTWH(58, 22.5, 7, 4.5), type: RoomType.wc),

    // ══════ Zentraler Korridor 300 (Erschliessung, mit Wendeltreppe) ══════
    Room(id: '300', label: '300 Erschliessung', bounds: Rect.fromLTWH(13, 15.5, 40, 11), type: RoomType.korridor),

    // ══════ Unteres Raumband (Süden, y 28–41) ══════
    Room(id: '331', label: '331', bounds: Rect.fromLTWH(1, 28, 9, 6.5)),
    Room(id: '330', label: '330', bounds: Rect.fromLTWH(1, 34.5, 9, 6.5)),
    Room(id: '325', label: '325 Aufenthalt', bounds: Rect.fromLTWH(10, 28, 16, 13), type: RoomType.aufenthalt),
    Room(id: '322', label: '322', bounds: Rect.fromLTWH(26, 28, 12, 13)),
    Room(id: '321', label: '321', bounds: Rect.fromLTWH(38, 28, 12, 13)),
    Room(id: '320', label: '320', bounds: Rect.fromLTWH(50, 28, 15, 13)),
  ],
  pois: [
    // Wendeltreppe im Korridor (rechtes Drittel, wie im Grundriss)
    PointOfInterest(id: 'spiral_stairs', label: 'Wendeltreppe', positionMeters: Offset(44, 21), icon: LucideIcons.footprints),
    // Treppenhäuser West / Ost
    PointOfInterest(id: 'stairs_west', label: 'Treppe', positionMeters: Offset(5.5, 19), icon: LucideIcons.footprints),
    PointOfInterest(id: 'stairs_east', label: 'Treppe', positionMeters: Offset(60.5, 19), icon: LucideIcons.footprints),
    // Lifte (in den Treppenhäusern)
    PointOfInterest(id: 'lift_west', label: 'Lift', positionMeters: Offset(8.5, 17), icon: LucideIcons.moveVertical),
    PointOfInterest(id: 'lift_east', label: 'Lift', positionMeters: Offset(57.5, 17), icon: LucideIcons.moveVertical),
    // WCs
    PointOfInterest(id: 'wc_west', label: 'WC', positionMeters: Offset(4.5, 24.5), icon: LucideIcons.bath),
    PointOfInterest(id: 'wc_east', label: 'WC', positionMeters: Offset(61.5, 24.5), icon: LucideIcons.bath),
  ],
  // Keine fest verdrahteten Lufträume: der exakte Atrium-Umriss wird nicht
  // vorgegeben (war zu ungenau). Nicht begehbare Bereiche definierst du bei
  // Bedarf im Begehbar-Tab — entweder indem du begehbare Zonen drumherum
  // zeichnest, oder (geplant) als gesperrte Zone.
  voids: [],
);

/// Alle bekannten Stockwerke — wird vom Setup-Screen für die Auswahl genutzt.
///
/// **HSLU Stock 3 steht bewusst zuerst**: er ist der Default beim Erststart
/// (`floorById(null)` → erstes Element) und hat ein echtes Grundriss-Bild, so
/// wirkt die Karte sofort „geladen". Der Test-Floor (leer, 4×3 m) ist nur fürs
/// lokale Entwickeln und steht darum hinten.
const List<FloorPlan> availableFloors = [
  hsluFloor3,
  homeTestFloor,
];

/// Stockwerk per ID auflösen, Default = erstes verfügbares.
FloorPlan floorById(String? id) {
  if (id == null) return availableFloors.first;
  return availableFloors.firstWhere(
    (f) => f.id == id,
    orElse: () => availableFloors.first,
  );
}
