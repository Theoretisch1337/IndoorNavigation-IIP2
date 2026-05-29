#ifndef CONFIG_H
#define CONFIG_H

// ============================================================
//  Indoor Navigation Beacon – Konfiguration
//  Version: 1.0.0
// ============================================================

#define FIRMWARE_VERSION_MAJOR 1
#define FIRMWARE_VERSION_MINOR 0
#define FIRMWARE_VERSION_PATCH 0
#define FIRMWARE_VERSION_STR "1.0.0"

// --- Beacon-Identifikation ---
// BEACON_ID wird via platformio.ini build_flags gesetzt (-D BEACON_ID=1)
// Pro Beacon eine eigene Nummer (1, 2, 3, ...)
// Gültiger Bereich: 1–65535 (0 = ungültig/nicht konfiguriert)
#ifndef BEACON_ID
  #define BEACON_ID 1
#endif

#if BEACON_ID == 0 || BEACON_ID > 65535
  #error "BEACON_ID muss zwischen 1 und 65535 liegen!"
#endif

// --- BLE Advertisement ---
// UUID: Identifiziert unser System / Firmware-Version
// Format: 128-bit UUID, bei Firmware-Update ändern
#define BEACON_UUID "550e8400-e29b-41d4-a716-446655440000"  // InNav v1

// Company ID: 0xFFFF = unassigned/test (Bluetooth SIG)
#define COMPANY_ID 0xFFFF

// Advertisement-Intervall (ms)
// Niedriger = genauer aber mehr Stromverbrauch
// 100ms  → sehr genau, ~1 Woche Akku
// 500ms  → gut, ~3-4 Wochen
// 1000ms → sparsam, ~6-8 Wochen
#ifndef ADV_INTERVAL_MS
  #define ADV_INTERVAL_MS 1000
#endif

// Min/Max Intervall-Jitter (BLE Spec empfiehlt leichten Jitter
// um Kollisionen zwischen Beacons zu vermeiden)
#define ADV_INTERVAL_MIN_MS ADV_INTERVAL_MS
#define ADV_INTERVAL_MAX_MS (ADV_INTERVAL_MS + 20)

// --- TX Power ---
// Kalibrierter RSSI bei 1m Abstand (int8, dBm)
// Muss pro Beacon einmalig gemessen werden!
// Typische Werte: -50 bis -70 dBm
#ifndef TX_POWER_CALIBRATED
  #define TX_POWER_CALIBRATED -59
#endif

// BLE Sendeleistung (NimBLE / Arduino-ESP32 v3.x)
// Wert in dBm: z.B. ESP_PWR_LVL_P9 = +9 dBm
// Gültige Werte: ESP_PWR_LVL_N12, _N9, _N6, _N3, _N0, _P3, _P6, _P9
#define BLE_TX_POWER ESP_PWR_LVL_P9  // Maximum für beste Reichweite

// --- Batterie ---
// ADC Pin für Akkustand
// XIAO ESP32 C6: GPIO2 (A0) ist der analoge Eingang
// Der Akkustand wird über einen internen Spannungsteiler gemessen.
// ACHTUNG: Den Pin vor dem Flashen am Board verifizieren!
#define BAT_ADC_PIN A0

// LiPo Spannungsgrenzen (gemessen am ADC nach Spannungsteiler)
// Volle LiPo = 4.2V, Leer = 3.0V (Entladeschlussspannung)
#define BAT_VOLTAGE_FULL  4.2f
#define BAT_VOLTAGE_EMPTY 3.0f

// ADC Referenzspannung des ESP32 C6
// Hinweis: Seit Umstellung auf analogReadMilliVolts() (eFuse-Werks-
// kalibrierung) wird dieser Wert nicht mehr zur Umrechnung gebraucht —
// nur noch als Dokumentation der nominalen ADC-Referenz.
#define ADC_REF_VOLTAGE 3.3f

// Spannungsteiler-Faktor (Verhältnis echte Spannung / Spannung am ADC-Pin)
// XIAO ESP32 C6: braucht EXTERNEN Spannungsteiler (siehe ADR-007) — Pin
// hat keinen internen Pfad zum Akku. Faktor 2.0 entspricht 2× gleiche
// Widerstände (z.B. 100 kΩ / 100 kΩ).
// WICHTIG: Nach Einbau des Spannungsteilers am echten Board kalibrieren!
#define BAT_VOLTAGE_DIVIDER 2.0f

// Anzahl ADC-Messungen zum Mitteln (Rauschunterdrückung)
#define BAT_ADC_SAMPLES 16  // Potenz von 2 für effizientes Mitteln

// --- LiPo Entladekurve (Lookup-Table) ---
// LiPo-Entladung ist NICHT linear! Diese Tabelle bildet die
// tatsächliche Kurve ab (Spannung → Prozent).
// Quelle: Typische LiPo 3.7V Entladekurve bei 0.1C
//
// Format: {Spannung, Prozent}
// Muss absteigend nach Spannung sortiert sein!
#define BAT_LUT_SIZE 11
static const float BAT_LUT_VOLTAGE[BAT_LUT_SIZE] = {
  4.20f, 4.10f, 4.00f, 3.90f, 3.80f,
  3.70f, 3.60f, 3.50f, 3.40f, 3.30f, 3.00f
};
static const uint8_t BAT_LUT_PERCENT[BAT_LUT_SIZE] = {
  100, 90, 80, 66, 52,
  40, 28, 18, 10, 4, 0
};

// --- Deep Sleep ---
// true = Deep Sleep zwischen Advertisements (spart Strom)
// false = aktiv bleiben (für Debugging)
//
// Mit Deep Sleep: ~7 µA Schlafstrom + ~50 ms Aufwach + Advertisement
// Ohne:           ~10 mA Dauerstrom (40× höher)
//
// Akku-Laufzeit (1000 mAh):
//   true  → 40-80 Tage
//   false → ~4 Tage
#define USE_DEEP_SLEEP true

// --- Watchdog ---
// Watchdog-Timer Timeout in Sekunden
// Startet den ESP32 neu falls die Firmware hängt
#define WDT_TIMEOUT_SEC 30

// --- Akku-Status-Flag (ohne Spannungsteiler) ---
// Solange kein externer Spannungsteiler verbaut ist (ADR-007), kann die rohe
// Akku-Spannung nicht über den ADC gemessen werden. Statt konstant 0% (was
// im Broadcast verwirrend wirkt) sendet die Firmware ein binäres Status-Flag,
// das auf dem Hardware-Brownout-Detektor basiert (misst VDD direkt):
//   - Normalbetrieb       → BATTERY_FLAG_OK       (100)
//   - nach Brownout-Reset → BATTERY_FLAG_CRITICAL (5, Akku am Entladeschluss)
//
// Sobald ein Spannungsteiler verbaut ist: BATTERY_SENSE_VIA_DIVIDER auf true
// setzen → die Firmware nutzt dann readBatteryPercent() für echte Prozentwerte
// ohne weitere Änderung in App oder C2-Server (gleiches Minor-Feld).
#define BATTERY_SENSE_VIA_DIVIDER false
#define BATTERY_FLAG_OK       100
#define BATTERY_FLAG_CRITICAL 5

// --- Brownout-Recovery (Akku-Schon-Modus) ---
// Der ESP32 löst bei zu niedriger Versorgungsspannung (leerer Akku) einen
// Brownout-Reset aus. Ohne Gegenmassnahme entstünde ein Reset-Loop:
// booten → advertisen → Spannung bricht ein → Brownout → booten → ...
// Das belastet den fast leeren Akku zusätzlich.
//
// Gegenmassnahme: Wird ein Brownout-Reset erkannt, geht der Beacon in einen
// Schon-Modus mit deutlich längerem Deep-Sleep-Intervall. Damit erholt sich
// die Akku-Spannung zwischen den Advertisements und der Reset-Loop wird
// vermieden. Nutzt KEINEN ADC (umgeht damit ADR-007) — basiert allein auf
// dem Hardware-Brownout-Detektor des ESP32 (misst VDD direkt).
#define BROWNOUT_RECOVERY_ENABLED true
#define BROWNOUT_RECOVERY_INTERVAL_MS 60000   // 60 s statt 1 s im Schon-Modus

// --- BLE-Timing-Konstante ---
// NimBLE/BLE-Spec misst Advertisement-Intervalle in Einheiten von 0.625 ms.
#define BLE_TIME_UNIT_MS 0.625f

// --- Debug ---
// Serial-Ausgabe aktivieren (für Entwicklung)
// ACHTUNG: Im Produktionsbetrieb auf false setzen (spart Strom)
#define DEBUG_SERIAL true

// --- Slow-Start (Pairing-Boost beim Power-On) ---
// Direkt nach einem Power-On (frisches Akku-Anstecken oder USB-C ein)
// advertisiert der Beacon kurzzeitig mit höherer Frequenz, damit er
// sofort in nRF Connect oder unserer Setup-Tab sichtbar wird.
// Greift NICHT bei Deep-Sleep-Wake (sonst würde es jeden Wake-Up
// auslösen und die Akku-Optimierung zunichte machen).
//
// SLOW_START_DURATION_MS = wie lange der Boost-Modus aktiv ist
// SLOW_START_INTERVAL_MS = Wake-Up-Intervall im Boost-Modus
#define SLOW_START_ENABLED true
#define SLOW_START_DURATION_MS 5000   // 5 s Boost nach Power-On
#define SLOW_START_INTERVAL_MS 250    // 4× pro Sekunde advertisen

// --- LED Heartbeat ---
// Bei jedem Advertisement-Zyklus ein kurzes Pulse auf der User-LED.
// Visuelles Lebenszeichen ohne Handy — sofort sichtbar dass der Beacon
// aktiv ist.
//
// Stromverbrauch: ~10 mA × 50 ms = 0.5 mAs pro Puls
// Bei 1 Hz Advertisement: ~0.01 mA Mittelwert (1% Akku-Verlust)
//
// HEARTBEAT_PULSE_MS = Dauer des LED-Pulses pro Wake-Up
#define HEARTBEAT_LED_ENABLED true
#define HEARTBEAT_PULSE_MS    50

// HEARTBEAT_LED_PIN nutzt LED_BUILTIN als Default (orange User-LED auf
// GPIO15 beim XIAO ESP32 C6). Bei anderen Boards entsprechend anpassen.
#ifndef HEARTBEAT_LED_PIN
  #define HEARTBEAT_LED_PIN LED_BUILTIN
#endif

// --- Power-Taster (BOOT als Aus-Schalter) ---
// GPIO9 (BOOT-Taster) ist NICHT RTC-faehig — auf dem ESP32-C6 koennen nur
// GPIO0-7 aus Deep-Sleep wecken. Ein schlafender Beacon "hoert" einen
// BOOT-Druck also nicht (ADR-008). Loesung: BOOT wird in der Wach-Phase
// gepollt. Wird er POWER_BUTTON_HOLD_MS durchgehend gehalten, geht der Beacon
// in einen unbefristeten Deep-Sleep ("Aus", ~7 uA). Wieder einschalten per
// RESET-Taster (Hardware-Reset).
//
// Bedienung: BOOT ca. 2-3 s gedrueckt halten (deckt eine Wach-Phase ab), die
// LED blinkt POWER_OFF_BLINKS-mal als Bestaetigung, dann ist der Beacon aus.
// Der RESET-Taster schaltet ihn wieder ein.
#define POWER_BUTTON_ENABLED true
#define POWER_BUTTON_PIN     9      // GPIO9 = BOOT-Taster (XIAO ESP32 C6)
#define POWER_BUTTON_HOLD_MS 1500   // so lange durchgehend halten -> Aus
#define POWER_BUTTON_POLL_MS 20     // Abtast-Intervall waehrend des Hold-Checks
#define POWER_OFF_BLINKS     3      // LED-Bestaetigung vor dem Abschalten

#endif // CONFIG_H
