# BLE Beacons – Indoor-Navigationssystem

## Übersicht

Die Beacons senden BLE-Advertisements (one-way, kein Empfang). Die Flutter-App empfängt die Pakete, berechnet die Position lokal und leitet Telemetrie-Daten (RSSI, Akkustand) an den C2-Server weiter.

```
ESP32 Beacon ──── BLE Advertisement ────► Flutter App ──── HTTP/REST ────► C2 Server
  (sendet)          (one-way)              (empfängt)                      (Monitoring)
```

## Hardware

- **Board:** Seeed Studio XIAO ESP32 C6
- **Akku:** Akyga LP803040 3.7V 1000mAh
- **Anschluss:** Pins/Stecker bevorzugt (einfacher Akkutausch) – evaluieren
- **Gehäuse:** 3D-Druck (HSLU FabLab)

## BLE-Paketformat

Basiert auf iBeacon-Struktur mit eigener Company ID.

### Advertisement-Paket

| Feld | Wert | Beschreibung |
|------|------|-------------|
| Company ID | `0xFFFF` | Unassigned / Test (Bluetooth SIG) |
| iBeacon Type | `0x02 0x15` | iBeacon-Kennung |
| UUID | `[projekt-spezifisch]` | Identifiziert Firmware-Version / System |
| Major | 2 Bytes | Beacon-ID (siehe unten) |
| Minor | 2 Bytes | Akkustand + Sequenznummer (siehe unten) |
| TX Power | 1 Byte (int8) | Kalibrierter RSSI bei 1m Abstand in dBm |

### Major – Beacon-Identifikation (2 Bytes / 16 Bits)

```
┌─────────────────────────────────────────────────────┐
│                  Major (uint16)                      │
│                  Beacon-ID                           │
│                  0–65535                              │
└─────────────────────────────────────────────────────┘
```

Einfach durchnummeriert (1, 2, 3, ...). Standortinfos (Gebäude, Stockwerk, x/y-Koordinaten) werden im C2-Server verwaltet, nicht im Paket. Vorteil: Bei Standortwechsel kein Re-Flash nötig.

### Minor – Telemetrie (2 Bytes / 16 Bits)

```
┌──────────────────────────┬──────────────────────────┐
│       Bits 15–8          │       Bits 7–0           │
│    Akkustand (uint8)     │   Sequenznummer (uint8)  │
│       0–100 %            │       0–255 (wraparound) │
└──────────────────────────┴──────────────────────────┘
```

**Akkustand:** Wird über ADC am BAT-Pin gelesen, auf 0–100% gemappt.

**Sequenznummer:** Inkrementiert bei jedem Advertisement um 1, wraparound bei 255→0.
- Erkennung von Duplikaten (BLE-Stack liefert selbes Paket doppelt)
- Erkennung von Paketverlust (Lücken in der Sequenz → schlechter Empfang)
- Hilft dem Kalman-Filter nur frische Werte zu verwenden

### TX Power

Nicht die aktuelle Sendeleistung, sondern der **kalibrierte RSSI-Wert bei genau 1m Abstand**. Wird einmalig pro Beacon gemessen und fest in die Firmware geschrieben. Die App berechnet daraus die ungefähre Distanz:

```
distance ≈ 10 ^ ((txPower - rssi) / (10 * n))
```

wobei `n` = Pfadverlust-Exponent (typisch 2.0–3.0 indoor).

### Beispiel-Paket

```
Company ID:  0xFFFF
UUID:        550e8400-e29b-41d4-a716-446655440000  (Beispiel, InNav v1)
Major:       0x0005        → Beacon #5
Minor:       0x5F2A        → 95% Akku, Sequenz #42
TX Power:    0xC5          → -59 dBm (bei 1m kalibriert)
```

## Firmware

### Projektstruktur (PlatformIO)

```
beacons/firmware/
├── platformio.ini          ← Board-Config, BEACON_ID, TX_POWER hier setzen
├── include/
│   └── config.h            ← Alle Einstellungen (UUID, Intervall, ADC, Debug)
└── src/
    └── main.cpp            ← Hauptprogramm (BLE + Batterie + Sleep)
```

### Setup (einmalig)

1. **VS Code** installieren + **PlatformIO Extension**
2. Ordner `beacons/firmware/` in VS Code öffnen
3. XIAO ESP32 C6 per USB-C anschliessen
4. In `platformio.ini`: `BEACON_ID` auf gewünschte Nummer setzen
5. PlatformIO → Upload (oder `pio run --target upload`)

### Konfiguration pro Beacon

In `platformio.ini` (build_flags) wird pro Beacon gesetzt:

| Flag | Beschreibung | Beispiel |
|------|-------------|---------|
| `BEACON_ID` | Eindeutige Nummer | `1`, `2`, `3`, ... |
| `TX_POWER_CALIBRATED` | Kalibrierter RSSI bei 1m (dBm) | `-59` |
| `ADV_INTERVAL_MS` | Advertisement-Intervall (ms) | `1000` |

UUID (gleich für alle Beacons) wird in `config.h` gesetzt.

### Flashen mehrerer Beacons

```bash
# Beacon 1 flashen
pio run --target upload -e xiao_esp32c6 --build-flag "-D BEACON_ID=1"

# Beacon 2 flashen
pio run --target upload -e xiao_esp32c6 --build-flag "-D BEACON_ID=2"

# ... oder: BEACON_ID in platformio.ini ändern → Upload
```

### Ablauf (Firmware-Loop)

```
Boot → Serial-Info → ADC-Init → BLE-Init → Loop:
  1. Akkustand lesen (ADC, 10× gemittelt)
  2. Minor zusammenbauen: [Akku %][Seq. Nr.]
  3. BLE Advertisement aktualisieren + senden
  4. Sequenznummer erhöhen (wraparound 255→0)
  5a. Deep Sleep aktiv:  → schlafen → Wakeup → zurück zu Boot
  5b. Deep Sleep aus:    → delay → zurück zu Schritt 1
```

### Akku laden

Kein Code nötig! Der XIAO ESP32 C6 hat einen eingebauten Lade-IC (ETA4054). USB-C anschliessen → Akku lädt automatisch. Funktioniert auch im Deep Sleep.

**Wichtig:** Laden über den Lade-IC funktioniert nur wenn der Akku an den BAT+/BAT− Pads angeschlossen ist (gelötet oder via Stecker). Über die GPIO-Pins ist kein Laden möglich.

### Energieverbrauch (geschätzt)

| Zustand | Stromverbrauch |
|---------|---------------|
| Deep Sleep | ~7 µA |
| BLE Advertisement | ~10–15 mA (kurz) |
| Durchschnitt bei 1s Intervall | ~0.5–1 mA |
| Laufzeit mit 1000mAh Akku | ~40–80 Tage |

## Datenfluss zur App / C2 Server

```
Beacon                    Flutter App                   C2 Server
  │                           │                             │
  │── BLE Adv. ──────────────►│                             │
  │   (Major, Minor, RSSI)    │                             │
  │                           │── POST /telemetry ─────────►│
  │                           │   {beacon_id, rssi,         │
  │                           │    battery, seq, timestamp} │
  │                           │                             │
  │                           │◄── GET /config ─────────────│
  │                           │   {beacon_positions,        │
  │                           │    map_data, graph}         │
  │                           │                             │
```

## Nächste Schritte

- [x] Firmware schreiben (PlatformIO / Arduino)
- [ ] PlatformIO installieren + ersten Beacon flashen
- [ ] BLE Advertisement mit nRF Connect verifizieren
- [ ] Akku-Anschluss klären: BAT-Pads (löten/Stecker) für Laden nötig
- [ ] TX Power bei 1m kalibrieren (pro Beacon messen!)
- [ ] RSSI vs. Distanz Kurve aufnehmen → **Coaching III Deliverable (14.04)**
- [ ] Deep Sleep aktivieren + Akkuverbrauch messen
