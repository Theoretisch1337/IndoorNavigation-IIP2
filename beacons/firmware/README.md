# InNav Beacon — Firmware

BLE-Beacons fuer die Indoor-Navigation (HSLU Campus Rotkreuz). Jeder Beacon
sendet ein iBeacon-aehnliches Advertising-Paket; die Mobile-App misst die
Signalstaerke (RSSI) und berechnet daraus die Position.

**Board:** Seeed Studio XIAO ESP32 C6 · **Framework:** PlatformIO + Arduino (C++)

---

## LED-Anzeige — was leuchtet wann

Der XIAO ESP32 C6 hat zwei LEDs mit unterschiedlicher Bedeutung:

| LED | Zustand | Bedeutung | Gesteuert von |
|---|---|---|---|
| **Orange** (User-LED, GPIO15) | kurzer Puls (~50 ms) | **Beacon laeuft / sendet** — ein Puls pro Advertising-Zyklus (1×/s, nach Power-On 5 s lang 4×/s) | Firmware (`HEARTBEAT_LED`) |
| **Orange** | **3× langsames Blinken** | **Beacon schaltet sich aus** (BOOT-Taster gehalten, siehe unten) | Firmware (ADR-008) |
| **Rot** (Lade-LED, neben USB-C) | leuchtet dauerhaft | **Akku laedt** | Hardware (Lade-IC) |
| **Rot** | aus (bei eingestecktem USB-C) | **Akku voll geladen** | Hardware (Lade-IC) |

> Die rote Lade-LED ist reine Hardware (Batterie-Lade-Chip) und wird **nicht**
> von der Firmware gesteuert oder ausgelesen — sie zeigt unabhaengig den
> Ladezustand. „Laeuft" (orange Puls) und „laedt" (rot) sind also gleichzeitig
> sichtbar: ein eingesteckter, sendender Beacon pulst orange **und** leuchtet
> rot, solange der Akku nicht voll ist.

---

## Tasten — ein- und ausschalten

Der XIAO ESP32 C6 hat **zwei Taster** und keinen Schiebe-Schalter:

| Taster | Aktion | Wirkung |
|---|---|---|
| **BOOT** (B) | ca. **2-3 s gedrueckt halten** | Beacon geht **aus** (Tiefschlaf, ~7 µA). LED blinkt 3× als Bestaetigung. |
| **RESET** (R) | kurz druecken | Beacon geht **an** (Neustart mit schnellem Pairing-Boost) |

**Warum Halten statt kurz Druecken?** Der Beacon schlaeft die meiste Zeit
(Stromsparen) und prueft den BOOT-Taster nur in seiner kurzen Wach-Phase.
Wer ihn ~2-3 s haelt, trifft sicher eine Wach-Phase. Hintergrund: GPIO9 (BOOT)
kann den ESP32-C6 nicht aus dem Tiefschlaf wecken (nur GPIO0-7 koennen das),
darum schaltet RESET wieder ein. Details: ADR-008.

> „Aus" ist Tiefschlaf, kein echtes 0 µA — fuer laengere Lagerung den Akku
> bzw. das USB-C-Kabel trennen.

---

## Build & Flash

Voraussetzungen + Schritt-fuer-Schritt: [`../../QUICKSTART.md`](../../QUICKSTART.md).

```bash
# Einzelner Beacon (BEACON_ID in platformio.ini setzen)
pio run --target upload

# Alle Beacons nacheinander mit aufsteigenden IDs
./flash_all.sh          # IDs 1..8
./flash_all.sh 3 5      # nur IDs 3, 4, 5
```

---

## Konfiguration (`include/config.h`)

| Define | Default | Zweck |
|---|---|---|
| `BEACON_ID` | per `platformio.ini` | eindeutige Beacon-Nummer (iBeacon-Major) |
| `ADV_INTERVAL_MS` | 1000 | Advertising-Intervall (kleiner = genauer, mehr Strom) |
| `TX_POWER_CALIBRATED` | -59 | gemessener RSSI bei 1 m (pro Beacon kalibrieren) |
| `USE_DEEP_SLEEP` | true | Tiefschlaf zwischen Advertisements (40-80 Tage statt ~4) |
| `HEARTBEAT_LED_ENABLED` | true | orange Lebenszeichen-LED |
| `POWER_BUTTON_ENABLED` | true | BOOT-Taster als Aus-Schalter |

---

## Advertising-Paket (iBeacon-Layout)

| Feld | Inhalt |
|---|---|
| Company ID | `0xFFFF` (Test/unassigned) |
| UUID | `550e8400-…-440000` (identifiziert die InNav-Firmware-Version) |
| Major | Beacon-ID |
| Minor | `[Akku-Status 8 Bit][Sequenznummer 8 Bit]` |
| TX Power | kalibrierter RSSI bei 1 m |

Der Akku-Status ist ein binaeres Flag (`100` = ok, `5` = kritisch nach
Brownout), solange kein externer Spannungsteiler verbaut ist — siehe ADR-007.
