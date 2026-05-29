import 'dart:math' as math;

/// Daten eines erkannten BLE-Beacons aus dem iBeacon-Advertisement.
///
/// Format des Advertisement-Pakets — siehe `code/beacons/firmware/`:
/// - **Major** = Beacon-ID (1..N)
/// - **Minor high byte** = Akku-Prozent (0..100)
/// - **Minor low byte**  = Sequenznummer (0..255, wraparound)
/// - **TxPower**         = kalibrierter RSSI bei 1 m (z. B. -59 dBm)
class BeaconScan {
  final String deviceId;
  final String name;
  final int rssi;
  final int? beaconId;
  final int? batteryPercent;
  final int? sequenceNum;
  final int? txPower;
  final DateTime lastSeen;

  const BeaconScan({
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.beaconId,
    this.batteryPercent,
    this.sequenceNum,
    this.txPower,
    required this.lastSeen,
  });

  /// `true`, wenn der Scan einem InNav-Beacon (UUID-Match) zugeordnet wurde.
  bool get isOurBeacon => beaconId != null;

  /// Geschätzte Distanz in Metern aus RSSI und kalibrierter TX-Power.
  ///
  /// Liefert `null`, wenn kein TX-Power-Wert bekannt ist (z. B. fremdes
  /// Gerät ohne iBeacon-Payload).
  double? get estimatedDistanceMeters {
    if (txPower == null) return null;
    return distanceFromRssi(rssi: rssi, txPower: txPower!);
  }

  /// Pfadverlust-Modell für Indoor-Umgebungen.
  ///
  /// Formel: `d ≈ 10 ^ ((txPower − rssi) / (10 · n))`
  ///
  /// Der Exponent `n` modelliert die Dämpfung der Umgebung:
  /// `n = 2.0` (Freifeld) bis `n = 4.0` (stark gestörter Innenraum).
  /// Default `n = 2.5` entspricht typischen Büro-/Korridor-Bedingungen
  /// (Zhao et al., 2018).
  ///
  /// Statisch ausgeführt, damit die Funktion ohne BLE-Mock unit-testbar ist.
  ///
  /// Parameter sind `num`, damit auch geglättete RSSI-Mittelwerte
  /// (`double` aus dem Moving-Average der PositionEngine) ohne
  /// Rundungs-Verlust akzeptiert werden.
  static double distanceFromRssi({
    required num rssi,
    required num txPower,
    double pathLossExponent = 2.5,
  }) {
    final ratio = (txPower - rssi) / (10.0 * pathLossExponent);
    return math.pow(10, ratio).toDouble();
  }

  /// Indiziert eine Scan-Sammlung nach Beacon-ID. Fremde Geräte ohne
  /// `beaconId` fallen weg. Mehrere Screens (Map, Setup, Kalibrierung)
  /// brauchen genau diese Sicht, um Distanzringe/Marker dem platzierten
  /// Beacon zuzuordnen.
  static Map<int, BeaconScan> indexByBeaconId(
    Iterable<BeaconScan> scans,
  ) {
    return {
      for (final scan in scans)
        if (scan.beaconId != null) scan.beaconId!: scan,
    };
  }

  BeaconScan copyWith({int? rssi, DateTime? lastSeen}) {
    return BeaconScan(
      deviceId: deviceId,
      name: name,
      rssi: rssi ?? this.rssi,
      beaconId: beaconId,
      batteryPercent: batteryPercent,
      sequenceNum: sequenceNum,
      txPower: txPower,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
