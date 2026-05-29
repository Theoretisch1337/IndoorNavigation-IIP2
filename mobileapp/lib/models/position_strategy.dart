/// Verfahren, mit dem die [PositionEngine] aus den BLE-Signalen eine
/// Position bestimmt. In den Einstellungen (Admin-Modus) umschaltbar.
///
/// Liegt bewusst in einem eigenen, abhängigkeitsfreien Model-File: sowohl
/// `services/storage.dart` (Persistenz der Wahl) als auch
/// `services/position_engine.dart` (Anwendung) referenzieren es — ohne
/// dieses neutrale File entstünde ein zyklischer Import zwischen beiden
/// Services.
enum PositionStrategy {
  /// RSSI → Pfadverlust-Distanz → Trilateration (Foy 1976). Default,
  /// braucht keine Vorab-Kalibrierung, nur platzierte Beacons.
  trilateration,

  /// RSSI-Signatur wird per k-Nearest-Neighbors gegen vorab erfasste
  /// Fingerprints abgeglichen. Genauer in stark gestörten Räumen, setzt
  /// aber kalibrierte Fingerprints voraus.
  fingerprinting,

  /// Beide Verfahren rechnen; das Ergebnis wird nach Confidence gewichtet
  /// gemittelt. Fällt automatisch auf das verfügbare Verfahren zurück,
  /// wenn eines kein Ergebnis liefert (z. B. noch keine Fingerprints).
  hybrid;

  /// Anzeigename für die UI.
  String get label => switch (this) {
        PositionStrategy.trilateration => 'Trilateration',
        PositionStrategy.fingerprinting => 'Fingerprinting',
        PositionStrategy.hybrid => 'Hybrid',
      };

  /// Stabiler Persistenz-Schlüssel (Enum-Name). Robust gegen Reihenfolge-
  /// Änderungen im Enum, anders als der Index.
  String get storageKey => name;

  static PositionStrategy fromStorageKey(String? key) {
    return PositionStrategy.values.firstWhere(
      (s) => s.name == key,
      orElse: () => PositionStrategy.trilateration,
    );
  }
}
