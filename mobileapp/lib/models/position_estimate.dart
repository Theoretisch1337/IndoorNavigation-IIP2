import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Methode, mit der eine Position berechnet wurde — wichtig für die
/// Confidence-Bewertung und die Bericht-Validation (Kap. 6).
enum PositionMethod {
  /// Nur ein Beacon sichtbar → Position = Beacon-Position selbst.
  /// Sehr grobe „in welchem Raum sind wir"-Aussage.
  proximity,

  /// Zwei Beacons → distanz-gewichtetes Mittel (1/d-Gewicht).
  /// Liegt auf der Verbindungslinie zwischen den Beacons.
  weightedCentroid,

  /// Drei oder mehr Beacons → lineares Least-Squares mit Referenz-Beacon-
  /// Subtraktion (Foy, 1976).
  trilateration,

  /// Position aus k-Nearest-Neighbors-Abgleich der aktuellen RSSI-Signatur
  /// gegen vorab erfasste Fingerprints (Spec 01).
  fingerprinting,

  /// Gewichtete Kombination aus Trilateration und Fingerprinting.
  hybrid,
}

/// Ergebnis einer Positionsberechnung.
///
/// Wird vom [`PositionEngine`] über `Stream<PositionEstimate?>`
/// publiziert. `null` bedeutet „aktuell keine berechenbare Position"
/// (z. B. keine platzierten Beacons sichtbar).
@immutable
class PositionEstimate {
  const PositionEstimate({
    required this.positionMeters,
    required this.confidence,
    required this.beaconsUsed,
    required this.method,
    this.residualMeters,
    required this.timestamp,
  });

  /// Position in Stockwerk-Koordinaten (Meter, Ursprung oben links).
  final Offset positionMeters;

  /// Vertrauen in das Ergebnis im Bereich `[0, 1]`.
  /// Setzt sich zusammen aus:
  /// - Anzahl genutzter Beacons (1=0.2, 2=0.5, 3+=residuumsabhängig)
  /// - Geometrie-Konsistenz (RMSE der Lateration-Residuen)
  final double confidence;

  final int beaconsUsed;
  final PositionMethod method;

  /// Wurzel-mittlerer-Quadrat-Fehler der Distanz-Residuen in Metern.
  /// Nur bei [PositionMethod.trilateration] gesetzt.
  /// Hoher Wert → Beacon-Positionen, RSSI oder Pfadverlust-Modell
  /// passen nicht zusammen (Multipath, falsche TX-Power, etc.).
  final double? residualMeters;

  final DateTime timestamp;

  /// Kopie mit überschriebener Position — für die EMA-Positions-Glättung
  /// in der PositionEngine (geglätteter Marker statt springender Rohwert).
  PositionEstimate copyWith({Offset? positionMeters}) {
    return PositionEstimate(
      positionMeters: positionMeters ?? this.positionMeters,
      confidence: confidence,
      beaconsUsed: beaconsUsed,
      method: method,
      residualMeters: residualMeters,
      timestamp: timestamp,
    );
  }
}
