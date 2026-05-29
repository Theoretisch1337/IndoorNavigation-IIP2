# Quickstart: Beacons flashen + App auf Handy

## 1. ESP32 Beacon flashen

### Voraussetzungen
- VS Code installiert
- PlatformIO Extension in VS Code installiert

### Schritte (pro Beacon)
```bash
# Terminal im Ordner: code/beacons/firmware/

# 1. BEACON_ID in platformio.ini setzen (1, 2, 3, ...)
#    build_flags = -D BEACON_ID=1

# 2. XIAO ESP32 C6 per USB-C anschliessen

# 3. Flashen
pio run --target upload

# 4. Serial Monitor öffnen (optional, zum Testen)
pio device monitor
```

### Für 3 Beacons
1. `BEACON_ID=1` setzen → flashen → USB abstecken
2. `BEACON_ID=2` setzen → flashen → USB abstecken
3. `BEACON_ID=3` setzen → flashen → USB abstecken

### Verifizieren
- **nRF Connect** App auf dem Handy installieren (gratis, Nordic Semiconductor)
- Scannen → du solltest "InNav Beacon #1/2/3" sehen
- RSSI, Major, Minor Werte prüfen

## 2. Flutter App auf Handy bringen

### Voraussetzungen
- Flutter SDK installiert (`flutter doctor` zum Prüfen)
- Für **iOS**: Xcode + Apple Developer Account (gratis reicht für eigenes Gerät)
- Für **Android**: USB-Debugging aktiviert auf dem Handy

### Schritte
```bash
# Terminal im Ordner: code/mobileapp/

# 1. Dependencies installieren
flutter pub get

# 2. Handy per USB anschliessen

# 3. Prüfen ob Gerät erkannt wird
flutter devices

# 4. App starten (direkt auf dem Handy)
flutter run
```

### iOS-spezifisch
```bash
# Falls Signing-Fehler:
# 1. ios/Runner.xcworkspace in Xcode öffnen
# 2. Runner → Signing & Capabilities → Team auswählen
# 3. Dann nochmal: flutter run
```

### Android-spezifisch
```bash
# USB-Debugging aktivieren:
# Einstellungen → Über das Telefon → 7× auf Build-Nummer tippen
# → Entwickleroptionen → USB-Debugging aktivieren
```

## 3. Demo-Ablauf (Coaching)

1. 3 Beacons einschalten (USB-C Powerbank oder Akku)
2. App auf Handy starten
3. "Scan" Button drücken
4. Rangliste zeigt Beacons sortiert nach Signalstärke
5. Beacon näher/weiter bewegen → RSSI ändert sich live
6. Akku-Stand und Sequenznummer sichtbar pro Beacon
