import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/beacon.dart';
import '../models/beacon_placement.dart';
import '../models/floor_plan.dart';
import 'app_toast.dart';

/// Interaktive Indoor-Karte auf Basis von `flutter_map` mit `CrsSimple`
/// (nicht-geografisches, kartesisches Koordinatensystem für Grundrisse).
///
/// Funktionen:
/// - **Grundriss-Bild** als Hintergrund (`floor.backgroundAsset`), sonst
///   ein heller Platzhalter-Hintergrund.
/// - **Pan + Pinch-Zoom + Rotation** (per Geste, von flutter_map).
/// - **Standort-Button** als Overlay (zentriert auf die User-Position bzw.
///   passt sonst den ganzen Grundriss ein).
/// - **Beacon- und User-Marker** mit `rotate: true` → bleiben beim Drehen
///   der Karte aufrecht und lesbar.
/// - **Tap → Meter-Koordinate** via [onTapMeters] (Beacon-Platzierung).
///
/// Koordinaten: das Floor-System ist Meter mit Ursprung oben-links (y nach
/// unten). CrsSimple hat die Breitenachse nach oben → Mapping mit Y-Flip
/// in [_toLatLng] / [_toMeter].
class IndoorMap extends StatefulWidget {
  const IndoorMap({
    super.key,
    required this.floor,
    this.placements = const [],
    this.beaconScans = const {},
    this.userPosition,
    this.onTapMeters,
    this.onBeaconTap,
    this.padding = 32.0,
    this.showDistanceRings = true,
    this.fingerprintPoints = const <Offset>[],
    this.walkableZones = const <Rect>[],
    this.showVoids = false,
  });

  final FloorPlan floor;
  final List<BeaconPlacement> placements;
  final Map<int, BeaconScan> beaconScans;
  final Offset? userPosition;
  final ValueChanged<Offset>? onTapMeters;

  /// Wird mit der Beacon-ID aufgerufen, wenn ein platzierter Beacon-Marker
  /// direkt angetippt wird (zuverlässiger als eine Meter-Distanz-Toleranz,
  /// besonders bei herausgezoomter Karte).
  final ValueChanged<int>? onBeaconTap;
  final double padding;
  final bool showDistanceRings;

  /// Positionen (Meter) bereits erfasster Fingerprints — werden als kleine
  /// grüne Punkte gezeichnet (Kalibrierungs-Screen).
  final List<Offset> fingerprintPoints;

  /// Begehbare Zonen (Meter-Rechtecke) — werden grün gefüllt gezeichnet
  /// (Begehbar-Screen, Feature B).
  final List<Rect> walkableZones;

  /// Wenn `true`, werden die Lufträume des Floors rot markiert (zeigt dem
  /// Admin den nicht-begehbaren Bereich, z. B. das Atrium).
  final bool showVoids;

  @override
  State<IndoorMap> createState() => _IndoorMapState();
}

class _IndoorMapState extends State<IndoorMap> {
  final MapController _map = MapController();

  // Zoom-Grenzen (CrsSimple): weit genug raus für den ganzen Grundriss,
  // weit rein fürs Detail des echten Grundriss-Bilds.
  static const double _minZoom = -8;
  static const double _maxZoom = 7;

  // Standort-Taste: ungefaehre Sichtbreite (Meter) beim Zentrieren auf den
  // Nutzer - genug Umgebung zum Wiederfinden, ohne extrem nah zu sein.
  static const double _locateSpanMeters = 14;

  // Design-System (MobileApp.pen).
  static const _cAccent = Color(0xFF2563EB);
  static const _cBg = Color(0xFFF4F4F5);

  FloorPlan get floor => widget.floor;

  // Meter (Ursprung oben-links, y↓) ↔ CrsSimple-LatLng (y↑).
  LatLng _toLatLng(Offset m) => LatLng(floor.heightMeters - m.dy, m.dx);
  Offset _toMeter(LatLng ll) =>
      Offset(ll.longitude, floor.heightMeters - ll.latitude);

  LatLngBounds get _bounds => LatLngBounds(
        const LatLng(0, 0),
        LatLng(floor.heightMeters, floor.widthMeters),
      );

  LatLng get _floorCenter =>
      LatLng(floor.heightMeters / 2, floor.widthMeters / 2);

  /// Zoom, bei dem der ganze Grundriss in [size] passt (mit [widget.padding]
  /// Rand). Bewusst MANUELL statt via `CameraFit`: CameraFit liefert mit
  /// `CrsSimple` einen falschen Wert (Karte landet viel zu nah → weiss). Bei
  /// CrsSimple gilt Pixel = Meter · scale(zoom) mit scale(zoom) = 256 · 2^zoom
  /// (flutter_map `Crs.scale`). Nach `zoom` aufgelöst, engere Achse gewinnt,
  /// damit beide Dimensionen sichtbar bleiben.
  double _fitZoom(Size size) {
    final usableW = math.max(1.0, size.width - 2 * widget.padding);
    final usableH = math.max(1.0, size.height - 2 * widget.padding);
    final zoomW = math.log(usableW / (floor.widthMeters * 256)) / math.ln2;
    final zoomH = math.log(usableH / (floor.heightMeters * 256)) / math.ln2;
    return math.min(zoomW, zoomH).clamp(_minZoom, _maxZoom);
  }

  /// Passt die Kamera auf den ganzen Grundriss ein (Reset-Fallback der
  /// Standort-Taste, wenn keine User-Position bekannt ist).
  void _fitWholeFloor() {
    _map.move(_floorCenter, _fitZoom(MediaQuery.sizeOf(context)));
  }

  /// Ziel-Zoom der Standort-Taste: zeigt rund [_locateSpanMeters] Meter um den
  /// Nutzer. Nie weiter raus als der ganze Grundriss (untere Klemme = Fit-Zoom),
  /// nie naeher als [_maxZoom].
  double _locateZoom(Size size) {
    final usableW = math.max(1.0, size.width - 2 * widget.padding);
    final z = math.log(usableW / (_locateSpanMeters * 256)) / math.ln2;
    return z.clamp(_fitZoom(size), _maxZoom);
  }

  /// „Standort"-Taste: zentriert auf die User-Position (falls vorhanden),
  /// sonst passt sie den ganzen Grundriss ein. Setzt die Rotation zurück.
  void _locateOrReset() {
    _map.rotate(0);
    final user = widget.userPosition;
    if (user != null) {
      // Auf den Nutzer zentrieren und sinnvoll reinzoomen (mind. der
      // Wiederfind-Zoom; ist die Karte schon naeher, bleibt sie es).
      final size = MediaQuery.sizeOf(context);
      _map.move(_toLatLng(user), math.max(_map.camera.zoom, _locateZoom(size)));
    } else {
      // Keine Position → ganzen Grundriss einpassen + erklären, warum nicht
      // zentriert wird (sonst wirkt die Taste „kaputt").
      _fitWholeFloor();
      if (mounted) {
        showToast(context, 'Noch keine Position - Beacons müssen sichtbar sein');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            crs: const CrsSimple(),
            // Start direkt mit korrektem Fit: Center + selbst berechneter Zoom.
            // MediaQuery-Grösse genügt — bei unseren Hochformat-Floors ist die
            // Breite die bindende Achse, also praktisch exakter Fit; im Zweifel
            // zoomt es eher etwas weiter raus (nie „weiss / zu nah").
            initialCenter: _floorCenter,
            initialZoom: _fitZoom(MediaQuery.sizeOf(context)),
            minZoom: _minZoom,
            maxZoom: _maxZoom,
            backgroundColor: _cBg,
            onTap: widget.onTapMeters == null
                ? null
                : (_, ll) {
                    final m = _toMeter(ll);
                    if (floor.boundsMeters.contains(m)) {
                      widget.onTapMeters!(m);
                    }
                  },
            interactionOptions: const InteractionOptions(
              // Pan + Zoom + Rotation per Geste; Doppel-Tap-Zoom aus, damit
              // er nicht mit dem Platzierungs-Tap kollidiert.
              flags: InteractiveFlag.pinchZoom |
                  InteractiveFlag.drag |
                  InteractiveFlag.rotate |
                  InteractiveFlag.flingAnimation |
                  InteractiveFlag.pinchMove,
            ),
          ),
          children: [
            if (floor.backgroundAsset != null)
              OverlayImageLayer(
                overlayImages: [
                  OverlayImage(
                    bounds: _bounds,
                    imageProvider: AssetImage(floor.backgroundAsset!),
                    gaplessPlayback: true,
                  ),
                ],
              )
            else
              ..._vectorRoomMarkers(),
            if (widget.showVoids && floor.voids.isNotEmpty) _voidLayer(),
            if (widget.walkableZones.isNotEmpty) _walkableLayer(),
            if (widget.showDistanceRings) _distanceRings(),
            if (widget.fingerprintPoints.isNotEmpty)
              MarkerLayer(markers: _fingerprintMarkers()),
            MarkerLayer(markers: _beaconMarkers()),
            if (widget.userPosition != null)
              MarkerLayer(markers: [_userMarker(widget.userPosition!)]),
          ],
        ),
        _locateControl(),
      ],
    );
  }

  // --- Layer ------------------------------------------------------------

  /// Rechteck (Meter) → flutter_map-Polygon (mit Y-Flip auf CrsSimple).
  Polygon _rectPolygon(Rect r, Color fill, Color border) {
    return Polygon(
      points: [
        _toLatLng(r.topLeft),
        _toLatLng(r.topRight),
        _toLatLng(r.bottomRight),
        _toLatLng(r.bottomLeft),
      ],
      color: fill,
      borderColor: border,
      borderStrokeWidth: 1.5,
    );
  }

  /// Begehbare Zonen (grün gefüllt).
  ///
  /// `simplificationTolerance: 0` schaltet die Punkt-Vereinfachung ab. Bei
  /// hohem Zoom wuerde sie unsere 4-Punkt-Rechtecke auf < 3 Punkte
  /// zusammenfallen lassen → Absturz beim Hit-Test (flutter_map #1933).
  /// Rechtecke brauchen ohnehin keine Vereinfachung.
  PolygonLayer _walkableLayer() => PolygonLayer(
        simplificationTolerance: 0,
        polygons: [
          for (final z in widget.walkableZones)
            _rectPolygon(z, const Color(0x3316A34A), const Color(0xFF16A34A)),
        ],
      );

  /// Lufträume / nicht begehbar (rot markiert). `simplificationTolerance: 0`
  /// aus demselben Grund wie [_walkableLayer] (Crash-Schutz bei hohem Zoom).
  PolygonLayer _voidLayer() => PolygonLayer(
        simplificationTolerance: 0,
        polygons: [
          for (final v in floor.voids)
            _rectPolygon(
                v.bounds, const Color(0x33DC2626), const Color(0xFFDC2626)),
        ],
      );

  /// RSSI-Distanzringe um live empfangene, platzierte Beacons.
  /// `useRadiusInMeter: true` → der Ring entspricht der geschätzten Distanz
  /// in CrsSimple-Einheiten (= Metern) und skaliert korrekt beim Zoomen.
  Widget _distanceRings() {
    final circles = <CircleMarker>[];
    for (final p in widget.placements) {
      final scan = widget.beaconScans[p.beaconId];
      final d = scan?.estimatedDistanceMeters;
      if (d == null || d <= 0) continue;
      circles.add(CircleMarker(
        point: _toLatLng(Offset(p.xMeters, p.yMeters)),
        radius: d,
        useRadiusInMeter: true,
        color: _cAccent.withValues(alpha: 0.06),
        borderColor: _cAccent.withValues(alpha: 0.35),
        borderStrokeWidth: 1,
      ));
    }
    return CircleLayer(circles: circles);
  }

  List<Marker> _fingerprintMarkers() {
    return [
      for (final p in widget.fingerprintPoints)
        Marker(
          point: _toLatLng(p),
          width: 14,
          height: 14,
          rotate: true,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A).withValues(alpha: 0.85),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
    ];
  }

  List<Marker> _beaconMarkers() {
    return [
      for (final p in widget.placements)
        Marker(
          point: _toLatLng(Offset(p.xMeters, p.yMeters)),
          width: 32,
          height: 32,
          rotate: true, // bleibt beim Kartendrehen aufrecht
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onBeaconTap == null
                ? null
                : () => widget.onBeaconTap!(p.beaconId),
            child: _BeaconChip(
              id: p.beaconId,
              live: widget.beaconScans[p.beaconId] != null,
            ),
          ),
        ),
    ];
  }

  Marker _userMarker(Offset userMeters) {
    return Marker(
      point: _toLatLng(userMeters),
      width: 44,
      height: 44,
      rotate: true,
      child: const _UserDot(),
    );
  }

  /// Fallback ohne Hintergrundbild (z. B. Home-Test-Floor): Räume als
  /// einfache Label-Marker, damit die Karte nicht leer ist.
  List<Widget> _vectorRoomMarkers() {
    return [
      MarkerLayer(
        markers: [
          for (final room in floor.rooms)
            Marker(
              point: _toLatLng(room.centerMeters),
              width: 80,
              height: 24,
              rotate: true,
              child: Center(
                child: Text(
                  room.id,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF71717A),
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  // --- Standort-Steuerung ----------------------------------------------

  Widget _locateControl() {
    // Über dem Apple Home-Indicator halten (sonst abgeschnitten / verdeckt).
    return Positioned(
      right: 12,
      bottom: 16 + MediaQuery.of(context).padding.bottom,
      child: _MapButton(
        icon: LucideIcons.locateFixed,
        tooltip: 'Auf meinen Standort zentrieren',
        onTap: _locateOrReset,
      ),
    );
  }
}

/// Beacon-Marker: blauer (live) bzw. grauer (inaktiv) Kreis mit Nummer.
class _BeaconChip extends StatelessWidget {
  const _BeaconChip({required this.id, required this.live});
  final int id;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: live ? const Color(0xFF2563EB) : const Color(0xFFD4D4D8),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$id',
        style: TextStyle(
          color: live ? Colors.white : const Color(0xFF71717A),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// User-Position: roter Punkt mit transparentem Pulse-Ring + weissem Rand.
class _UserDot extends StatelessWidget {
  const _UserDot();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFDC2626).withValues(alpha: 0.18),
            shape: BoxShape.circle,
          ),
        ),
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: const Color(0xFFDC2626),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
          ),
        ),
      ],
    );
  }
}

/// Runder Kartensteuerungs-Button (Standort / Reset).
class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        icon: Icon(icon, size: 22, color: const Color(0xFF2563EB)),
        tooltip: tooltip,
        onPressed: onTap,
      ),
    );
  }
}

