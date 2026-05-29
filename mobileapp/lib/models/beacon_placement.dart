/// Statisch konfigurierte Position eines Beacons auf einem Stockwerk.
///
/// Wird über das Setup-Screen vom User platziert und persistiert.
/// Verbindet die `beaconId` (Major-Feld aus dem iBeacon-Advertisement,
/// siehe `firmware/include/config.h`) mit einer Koordinate in Metern
/// auf einem konkreten [floorId].
class BeaconPlacement {
  const BeaconPlacement({
    required this.beaconId,
    required this.floorId,
    required this.xMeters,
    required this.yMeters,
    this.txPowerOverride,
    this.label,
  });

  /// Beacon-ID = Major-Feld im iBeacon-Payload, gesetzt in der Firmware
  /// via `-D BEACON_ID=N`.
  final int beaconId;

  /// Stockwerk-Schlüssel — siehe `models/floor_plan.dart`.
  final String floorId;

  /// X-Koordinate in Metern, gemessen vom Map-Ursprung (linke obere Ecke).
  final double xMeters;

  /// Y-Koordinate in Metern, gemessen vom Map-Ursprung (linke obere Ecke).
  final double yMeters;

  /// Optionaler Override für die TX-Power. Sinnvoll, wenn ein Beacon
  /// einzeln nachkalibriert wurde, ohne neue Firmware zu flashen.
  /// Wenn `null`, wird der vom Beacon selbst gesendete Wert verwendet.
  final int? txPowerOverride;

  /// Optionales Label für die UI (z. B. „Eingang Pilatus 3.01").
  final String? label;

  Map<String, dynamic> toJson() => {
        'beaconId': beaconId,
        'floorId': floorId,
        'x': xMeters,
        'y': yMeters,
        if (txPowerOverride != null) 'tx': txPowerOverride,
        if (label != null) 'label': label,
      };

  factory BeaconPlacement.fromJson(Map<String, dynamic> json) {
    return BeaconPlacement(
      beaconId: json['beaconId'] as int,
      floorId: json['floorId'] as String,
      xMeters: (json['x'] as num).toDouble(),
      yMeters: (json['y'] as num).toDouble(),
      txPowerOverride: json['tx'] as int?,
      label: json['label'] as String?,
    );
  }

  /// Sentinel, um `txPowerOverride`/`label` gezielt auf `null` setzen zu können
  /// (mit `?? this.x` liesse sich ein bewusstes Löschen sonst nicht abbilden).
  static const Object _unset = Object();

  BeaconPlacement copyWith({
    double? xMeters,
    double? yMeters,
    Object? txPowerOverride = _unset,
    Object? label = _unset,
  }) {
    return BeaconPlacement(
      beaconId: beaconId,
      floorId: floorId,
      xMeters: xMeters ?? this.xMeters,
      yMeters: yMeters ?? this.yMeters,
      txPowerOverride: identical(txPowerOverride, _unset)
          ? this.txPowerOverride
          : txPowerOverride as int?,
      label: identical(label, _unset) ? this.label : label as String?,
    );
  }

  @override
  String toString() =>
      'BeaconPlacement(#$beaconId @ ($xMeters, $yMeters)m on $floorId)';
}
