// ============================================================
//  Indoor Navigation Beacon – Firmware
//  Board: Seeed Studio XIAO ESP32 C6
//  Protokoll: iBeacon-ähnlich mit Company ID 0xFFFF
//  Kompatibel mit: Arduino-ESP32 v3.x (NimBLE)
// ============================================================
//
//  Paketformat (iBeacon-Layout):
//    Company ID:  0xFFFF (test/unassigned)
//    UUID:        128-bit (identifiziert Firmware-Version)
//    Major:       Beacon-ID (uint16, durchnummeriert)
//    Minor:       [Akku % (8 Bit)] [Sequenznummer (8 Bit)]
//    TX Power:    Kalibrierter RSSI bei 1m (int8)
//
// ============================================================

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEAdvertising.h>
#include <BLEUtils.h>
#include <esp_task_wdt.h>
#include <esp_system.h>          // für esp_reset_reason()
#include "config.h"

// --- Globale Variablen ---
BLEAdvertising* pAdvertising = nullptr;

// Reset-Grund einmal in setup() lesen und cachen. esp_reset_reason() liefert
// nach dem ersten Aufruf zwar weiterhin denselben Wert, aber wir wollen ihn
// nicht mehrfach abrufen (Aufrufe in Hotpath wie isInSlowStart() vermeiden).
static esp_reset_reason_t bootResetReason = ESP_RST_UNKNOWN;

// RTC_DATA_ATTR: Überlebt Deep Sleep (wird im RTC-Memory gespeichert)
RTC_DATA_ATTR uint8_t sequenceNumber = 0;
RTC_DATA_ATTR uint32_t bootCount = 0;
RTC_DATA_ATTR uint32_t uptimeSeconds = 0;  // gesamte Lifetime, überlebt Deep Sleep

// ============================================================
//  Diagnostik (Reset-Reason + Uptime)
// ============================================================

/**
 * Liefert den gecachten Reset-Grund als kurzen, menschlich lesbaren String.
 * Hilfreich um zu erkennen ob der Beacon einen Watchdog-Reset hatte
 * oder regulär aus Deep-Sleep aufgewacht ist.
 */
static const char* resetReasonString() {
  switch (bootResetReason) {
    case ESP_RST_POWERON:   return "POWERON";       // Strom angelegt
    case ESP_RST_EXT:       return "EXT_RESET";     // RESET-Pin
    case ESP_RST_SW:        return "SW_RESET";      // esp_restart()
    case ESP_RST_PANIC:     return "PANIC";         // Exception/Crash
    case ESP_RST_INT_WDT:   return "INT_WDT";       // Interrupt-Watchdog
    case ESP_RST_TASK_WDT:  return "TASK_WDT";      // Task-Watchdog (unser WDT)
    case ESP_RST_WDT:       return "OTHER_WDT";     // Anderer Watchdog
    case ESP_RST_DEEPSLEEP: return "DEEP_SLEEP";    // Wake aus Deep Sleep
    case ESP_RST_BROWNOUT:  return "BROWNOUT";      // Akku zu schwach
    case ESP_RST_SDIO:      return "SDIO";
    default:                return "UNKNOWN";
  }
}

// ============================================================
//  Batterie
// ============================================================

/**
 * Konvertiert eine LiPo-Spannung in Prozent anhand der Lookup-Tabelle.
 * Interpoliert linear zwischen den Stützpunkten.
 * LiPo-Entladung ist NICHT linear → Lookup ist genauer als V→% Formel.
 */
static uint8_t voltageToBatteryPercent(float voltage) {
  // Über Maximum
  if (voltage >= BAT_LUT_VOLTAGE[0]) {
    return BAT_LUT_PERCENT[0];
  }
  // Unter Minimum
  if (voltage <= BAT_LUT_VOLTAGE[BAT_LUT_SIZE - 1]) {
    return BAT_LUT_PERCENT[BAT_LUT_SIZE - 1];
  }

  // Passenden Abschnitt in der Tabelle finden
  for (int i = 0; i < BAT_LUT_SIZE - 1; i++) {
    if (voltage >= BAT_LUT_VOLTAGE[i + 1]) {
      // Lineare Interpolation zwischen Stützpunkt i und i+1
      float vHigh = BAT_LUT_VOLTAGE[i];
      float vLow  = BAT_LUT_VOLTAGE[i + 1];
      float pHigh = (float)BAT_LUT_PERCENT[i];
      float pLow  = (float)BAT_LUT_PERCENT[i + 1];

      float ratio = (voltage - vLow) / (vHigh - vLow);
      return (uint8_t)(pLow + ratio * (pHigh - pLow));
    }
  }

  return 0;
}

/**
 * Liest die Akkuspannung über den ADC und gibt den Ladestand
 * als Prozentwert (0-100) zurück.
 */
static uint8_t readBatteryPercent() {
  uint32_t mvSum = 0;

  // analogReadMilliVolts() nutzt die im eFuse hinterlegte Werks-Kalibrierung
  // des ESP32-C6-ADC und liefert direkt Millivolt — deutlich genauer als die
  // manuelle Umrechnung über analogRead() / 4095, die die ADC-Nichtlinearität
  // ignoriert.
  for (int i = 0; i < BAT_ADC_SAMPLES; i++) {
    mvSum += analogReadMilliVolts(BAT_ADC_PIN);
    delayMicroseconds(100);
  }

  float pinMilliVolts = (float)mvSum / BAT_ADC_SAMPLES;

  // Spannung am Pin → echte Akkuspannung (× externer Spannungsteiler)
  float voltage = (pinMilliVolts / 1000.0f) * BAT_VOLTAGE_DIVIDER;

  // Spannung → Prozent über LiPo-Entladekurve
  uint8_t percent = voltageToBatteryPercent(voltage);

  #if DEBUG_SERIAL
    Serial.printf("[BAT] Pin: %.0f mV | Akku: %.2f V | Ladung: %d%%\n",
                  pinMilliVolts, voltage, percent);
  #endif

  return percent;
}

// ============================================================
//  iBeacon Payload (manuell gebaut)
// ============================================================

/**
 * UUID-String ("550e8400-e29b-...") in 16-Byte Array konvertieren.
 * iBeacon sendet UUID in Big-Endian.
 */
static void parseUUID(const char* uuidStr, uint8_t* out) {
  int idx = 0;
  const char* p = uuidStr;
  while (*p != '\0' && idx < 16) {
    if (*p == '-') { p++; continue; }
    // Beide Hex-Zeichen müssen vorhanden sein, sonst war der String
    // unerwartet kurz — Schleife sauber beenden statt ins Leere lesen.
    if (p[1] == '\0') break;
    char hex[3] = { p[0], p[1], '\0' };
    out[idx++] = (uint8_t)strtoul(hex, nullptr, 16);
    p += 2;
  }
}

/**
 * Baut den iBeacon Advertisement Payload manuell auf.
 *
 * iBeacon Paketformat (30 Bytes):
 *   [0-1]  Company ID (Little-Endian)
 *   [2]    iBeacon Typ (0x02)
 *   [3]    Länge (0x15 = 21 Bytes)
 *   [4-19] UUID (16 Bytes, Big-Endian)
 *   [20-21] Major (Big-Endian)
 *   [22-23] Minor (Big-Endian)
 *   [24]   TX Power (int8, kalibriert bei 1m)
 */
static String buildIBeaconPayload(uint8_t batteryPercent) {
  uint8_t payload[25];

  // Company ID (Little-Endian)
  payload[0] = COMPANY_ID & 0xFF;
  payload[1] = (COMPANY_ID >> 8) & 0xFF;

  // iBeacon Typ + Länge
  payload[2] = 0x02;  // iBeacon indicator
  payload[3] = 0x15;  // 21 bytes following

  // UUID (Big-Endian)
  parseUUID(BEACON_UUID, &payload[4]);

  // Major = Beacon-ID (Big-Endian)
  payload[20] = (BEACON_ID >> 8) & 0xFF;
  payload[21] = BEACON_ID & 0xFF;

  // Minor = [Akku %][Sequenznummer] (Big-Endian)
  payload[22] = batteryPercent;
  payload[23] = sequenceNumber;

  // TX Power (kalibrierter RSSI bei 1m)
  payload[24] = (uint8_t)((int8_t)TX_POWER_CALIBRATED);

  // String aus raw bytes bauen (Arduino-String unterstützt Binärdaten via
  // Pointer+Länge-Konstruktor — kann Null-Bytes enthalten)
  return String((const char*)payload, sizeof(payload));
}

// ============================================================
//  BLE Advertisement
// ============================================================

/**
 * Initialisiert BLE und konfiguriert das Advertising.
 * Gibt true zurück bei Erfolg, false bei Fehler.
 */
static bool initBLE() {
  // BLE-Device-Name: erscheint als "InNav-N" in BLE-Scannern wie nRF Connect.
  // Hilft beim Identifizieren physischer Beacons im Feld (im Gegensatz zu
  // einer anonymen MAC-Adresse).
  char deviceName[16];
  snprintf(deviceName, sizeof(deviceName), "InNav-%d", BEACON_ID);
  BLEDevice::init(String(deviceName));

  // Sendeleistung setzen (Maximum für beste Reichweite)
  BLEDevice::setPower(BLE_TX_POWER);

  // Advertising konfigurieren
  pAdvertising = BLEDevice::getAdvertising();
  if (pAdvertising == nullptr) {
    #if DEBUG_SERIAL
      Serial.println("[BLE] FEHLER: Advertising-Objekt ist null");
    #endif
    return false;
  }

  // Advertisement-Intervall setzen (BLE-Spec-Einheit: 0.625 ms)
  uint16_t advMin = (uint16_t)(ADV_INTERVAL_MIN_MS / BLE_TIME_UNIT_MS);
  uint16_t advMax = (uint16_t)(ADV_INTERVAL_MAX_MS / BLE_TIME_UNIT_MS);
  pAdvertising->setMinInterval(advMin);
  pAdvertising->setMaxInterval(advMax);

  return true;
}

/**
 * Heartbeat-LED-Puls: kurzes visuelles Lebenszeichen pro Wake-Up.
 * Frühzeitig pulsen (vor BLE-Update), damit der User den Puls auch dann
 * sieht, wenn der BLE-Stack durch einen Fehler hängt.
 */
static void heartbeatPulse() {
  #if HEARTBEAT_LED_ENABLED
    digitalWrite(HEARTBEAT_LED_PIN, HIGH);
    delay(HEARTBEAT_PULSE_MS);
    digitalWrite(HEARTBEAT_LED_PIN, LOW);
  #endif
}

/**
 * Liefert den Akku-Status-Wert fürs iBeacon-Minor-Feld.
 *
 * Ohne externen Spannungsteiler (ADR-007) ist keine echte Spannungs-Messung
 * möglich, daher ein binäres Flag auf Basis des Brownout-Detektors:
 * - OK (100) im Normalbetrieb
 * - CRITICAL (5) nach einem Brownout-Reset (Akku am Entladeschluss ~2.9 V)
 *
 * Mit verbautem Spannungsteiler (BATTERY_SENSE_VIA_DIVIDER) liefert
 * readBatteryPercent() den echten Prozentwert.
 */
static uint8_t batteryStatusValue() {
  #if BATTERY_SENSE_VIA_DIVIDER
    return readBatteryPercent();
  #else
    #if DEBUG_SERIAL
      // ADC-Rohwert zur Diagnose mitloggen (ohne Spannungsteiler ~0)
      const uint8_t adcRaw = readBatteryPercent();
      Serial.printf("[BAT] ADC-Rohwert (ohne Teiler): %d%% → Flag-Modus aktiv\n",
                    adcRaw);
    #endif
    return (bootResetReason == ESP_RST_BROWNOUT)
        ? BATTERY_FLAG_CRITICAL
        : BATTERY_FLAG_OK;
  #endif
}

/**
 * Baut das iBeacon-Advertisement-Paket und aktualisiert die Daten.
 */
static void updateAdvertisement() {
  // Visueller Heartbeat zuerst — zeigt dass der Beacon-Loop läuft,
  // unabhängig vom Erfolg der BLE-Operationen die nachfolgen
  heartbeatPulse();

  uint8_t batteryPercent = batteryStatusValue();

  // iBeacon Payload manuell bauen
  String beaconPayload = buildIBeaconPayload(batteryPercent);

  // Advertisement-Daten setzen
  BLEAdvertisementData advData;
  advData.setFlags(0x06);  // LE General Discoverable, BR/EDR nicht unterstützt

  // setManufacturerData fügt AD Type 0xFF automatisch hinzu
  advData.setManufacturerData(beaconPayload);
  pAdvertising->setAdvertisementData(advData);

  #if DEBUG_SERIAL
    Serial.printf("[ADV] Beacon #%d | Akku: %d%% | Seq: %d | TX: %d dBm\n",
                  BEACON_ID, batteryPercent, sequenceNumber,
                  TX_POWER_CALIBRATED);
  #endif

  // Sequenznummer erhöhen (wraparound 255 → 0 ist implizit durch uint8_t)
  sequenceNumber++;
}

// ============================================================
//  Deep Sleep
// ============================================================

/**
 * Versetzt den ESP32 in Deep Sleep für die konfigurierte Dauer.
 * Im Deep Sleep verbraucht der ESP32 nur ~7 µA.
 */
static void enterDeepSleep() {
  // WDT zuerst füttern — BLEDevice::deinit() kann je nach Stack-Last
  // mehrere hundert Millisekunden brauchen. Ohne Reset könnte der
  // 30-s-Watchdog am Ende einer langen Slow-Start-Phase über die Grenze
  // laufen und einen Panic-Reboot statt sauberen Sleep-Wake auslösen.
  esp_task_wdt_reset();

  #if DEBUG_SERIAL
    Serial.println("[SLEEP] Entering Deep Sleep...");
    Serial.flush();
  #endif

  // BLE stoppen vor Sleep
  BLEDevice::deinit(false);

  // Sleep-Intervall bestimmen. Im Normalfall ADV_INTERVAL_MS. Wurde der
  // letzte Boot durch einen Brownout (leerer Akku) ausgelöst, in einen
  // Schon-Modus mit längerem Intervall wechseln — verhindert den
  // strom-fressenden Reset-Loop und gibt der Akku-Spannung Zeit sich zu
  // erholen. Basiert auf dem Hardware-Brownout-Detektor (kein ADC, ADR-007
  // umgangen).
  uint32_t sleepMs = ADV_INTERVAL_MS;
  #if BROWNOUT_RECOVERY_ENABLED
    if (bootResetReason == ESP_RST_BROWNOUT) {
      sleepMs = BROWNOUT_RECOVERY_INTERVAL_MS;
      #if DEBUG_SERIAL
        Serial.printf("[SLEEP] Brownout-Schon-Modus: %lu ms Intervall\n", sleepMs);
      #endif
    }
  #endif

  // Wakeup-Timer setzen
  esp_sleep_enable_timer_wakeup((uint64_t)sleepMs * 1000ULL);

  // Deep Sleep starten
  esp_deep_sleep_start();
}

// ============================================================
//  Power-Taster (BOOT als Aus-Schalter)
// ============================================================

/**
 * Prueft, ob der BOOT-Taster (GPIO9) durchgehend fuer POWER_BUTTON_HOLD_MS
 * gedrueckt gehalten wird. Steigt sofort aus, wenn der Taster gar nicht
 * gedrueckt ist (Normalfall) -> kein Akku-Impact. Nur bei echtem Druck wird
 * die Halte-Dauer verifiziert (Entprellung + Schutz vor versehentlichem
 * Antippen).
 */
static bool powerButtonHeld() {
  #if POWER_BUTTON_ENABLED
    if (digitalRead(POWER_BUTTON_PIN) != LOW) {
      return false;  // nicht gedrueckt -> sofort raus
    }
    const uint32_t start = millis();
    while (millis() - start < POWER_BUTTON_HOLD_MS) {
      if (digitalRead(POWER_BUTTON_PIN) != LOW) {
        return false;  // zu frueh losgelassen
      }
      esp_task_wdt_reset();
      delay(POWER_BUTTON_POLL_MS);
    }
    return true;
  #else
    return false;
  #endif
}

/**
 * Schaltet den Beacon "aus": unbefristeter Deep-Sleep OHNE Timer-Wakeup. Der
 * Chip verbraucht dann nur ~7 uA und wacht erst durch den RESET-Taster
 * (Hardware-Reset) oder einen Power-Cycle wieder auf. GPIO9 (BOOT) kann nicht
 * als Wake-Quelle dienen, da nicht RTC-faehig (ADR-008).
 */
static void enterPermanentSleep() {
  esp_task_wdt_reset();

  #if DEBUG_SERIAL
    Serial.println("[POWER] BOOT gehalten -> Beacon AUS (Deep-Sleep bis RESET)");
    Serial.flush();
  #endif

  // Visuelle Bestaetigung: mehrmals blinken = "ich schalte ab"
  #if HEARTBEAT_LED_ENABLED
    for (int i = 0; i < POWER_OFF_BLINKS; i++) {
      digitalWrite(HEARTBEAT_LED_PIN, HIGH);
      delay(150);
      digitalWrite(HEARTBEAT_LED_PIN, LOW);
      delay(150);
    }
  #endif

  BLEDevice::deinit(false);

  // KEIN esp_sleep_enable_timer_wakeup() -> kein automatisches Aufwachen.
  esp_deep_sleep_start();
}

// ============================================================
//  Setup-Helfer
// ============================================================

/**
 * Aktualisiert den Uptime-Counter abhängig vom Reset-Grund.
 * Power-On / SW-Reset → von Null beginnen.
 * Deep-Sleep-Wake     → Intervall-Dauer addieren (Approximation).
 */
static void updateUptimeOnBoot() {
  switch (bootResetReason) {
    case ESP_RST_POWERON:
      uptimeSeconds = 0;
      break;
    case ESP_RST_DEEPSLEEP:
      uptimeSeconds += (ADV_INTERVAL_MS / 1000);
      break;
    default:
      // Andere Reset-Gründe (WDT, Panic, ...): Uptime unverändert lassen
      break;
  }
}

/**
 * Serial initialisieren und Boot-Banner mit Diagnose-Infos ausgeben.
 */
static void initSerialAndBanner() {
  #if DEBUG_SERIAL
    Serial.begin(115200);
    delay(100);
    Serial.println();
    Serial.println("================================");
    Serial.printf("  InNav-%d  (Firmware v%s)\n", BEACON_ID, FIRMWARE_VERSION_STR);
    Serial.println("================================");
    Serial.printf("  Reset-Grund: %s\n", resetReasonString());
    Serial.printf("  Boot-Count:  #%lu\n", bootCount);
    Serial.printf("  Uptime:      %lu s\n", uptimeSeconds);
    Serial.printf("  Sequenz:     %d\n", sequenceNumber);
    Serial.println("  ---");
    Serial.printf("  BLE-Name:    InNav-%d\n", BEACON_ID);
    Serial.printf("  UUID:        %s\n", BEACON_UUID);
    Serial.printf("  TX-Power:    %d dBm @ 1 m\n", TX_POWER_CALIBRATED);
    Serial.printf("  Intervall:   %d ms\n", ADV_INTERVAL_MS);
    Serial.printf("  Deep-Sleep:  %s\n", USE_DEEP_SLEEP ? "aktiv" : "deaktiviert");
    Serial.printf("  Power-Btn:   %s (BOOT halten = aus, RESET = an)\n",
                  POWER_BUTTON_ENABLED ? "aktiv" : "aus");
    Serial.println("================================");
  #endif
}

/**
 * Watchdog aktivieren (ESP-IDF v5.x API).
 * Startet den ESP32 neu falls die Firmware mehr als WDT_TIMEOUT_SEC hängt.
 */
static void initWatchdog() {
  esp_task_wdt_config_t wdtConfig = {
    .timeout_ms = WDT_TIMEOUT_SEC * 1000,
    .idle_core_mask = 0,
    .trigger_panic = true
  };
  esp_task_wdt_reconfigure(&wdtConfig);
  esp_task_wdt_add(NULL);
}

/**
 * LED-Pin als Ausgang konfigurieren und auf LOW setzen.
 */
static void initHeartbeatLed() {
  #if HEARTBEAT_LED_ENABLED
    pinMode(HEARTBEAT_LED_PIN, OUTPUT);
    digitalWrite(HEARTBEAT_LED_PIN, LOW);
  #endif
}

/**
 * BOOT-Taster (GPIO9) als Eingang konfigurieren. Der Taster zieht gegen GND,
 * das Board hat einen Pull-Up (R6) -> Ruhepegel HIGH, gedrueckt = LOW.
 */
static void initPowerButton() {
  #if POWER_BUTTON_ENABLED
    pinMode(POWER_BUTTON_PIN, INPUT_PULLUP);
  #endif
}

// ============================================================
//  Setup
// ============================================================

void setup() {
  bootCount++;

  // Reset-Grund VOR allem anderen lesen und cachen — kann bei Diagnose helfen
  // (z.B. „Warum ist der Beacon vor 5 Min neu gestartet? → WDT")
  bootResetReason = esp_reset_reason();

  updateUptimeOnBoot();
  initSerialAndBanner();
  initWatchdog();

  // ADC konfigurieren
  analogReadResolution(12);

  initHeartbeatLed();
  initPowerButton();

  // BLE initialisieren
  if (!initBLE()) {
    #if DEBUG_SERIAL
      Serial.println("[FEHLER] BLE Init fehlgeschlagen! Neustart in 5s...");
    #endif
    delay(5000);
    ESP.restart();
  }

  // Erstes Advertisement senden
  updateAdvertisement();

  // Advertising starten
  pAdvertising->start();

  #if DEBUG_SERIAL
    Serial.println("[BLE] Advertising gestartet");
  #endif
}

// ============================================================
//  Loop
// ============================================================

/**
 * Prüft, ob der Beacon sich im Slow-Start-Boost-Modus befindet.
 * Wahr nur nach einem echten Power-On (nicht nach Deep-Sleep-Wake)
 * und nur für die ersten SLOW_START_DURATION_MS Millisekunden.
 */
static bool isInSlowStart() {
  #if SLOW_START_ENABLED
    return bootResetReason == ESP_RST_POWERON
        && millis() < SLOW_START_DURATION_MS;
  #else
    return false;
  #endif
}

void loop() {
  esp_task_wdt_reset();

  // BOOT-Taster gedrueckt gehalten -> Beacon ausschalten. GPIO9 ist nicht
  // RTC-faehig und weckt daher nicht aus Deep-Sleep (ADR-008), also wird hier
  // in der Wach-Phase gepollt. Der RESET-Taster schaltet wieder ein.
  #if POWER_BUTTON_ENABLED
    if (powerButtonHeld()) {
      enterPermanentSleep();  // kehrt nie zurueck (bis RESET / Power-Cycle)
    }
  #endif

  // Slow-Start: erste Sekunden nach Power-On häufiger advertisen,
  // damit der Beacon sofort in Setup-Apps sichtbar ist (siehe Kommentar
  // in config.h zu SLOW_START_*). Greift NICHT bei Deep-Sleep-Wake.
  if (isInSlowStart()) {
    delay(SLOW_START_INTERVAL_MS);
    pAdvertising->stop();
    updateAdvertisement();
    pAdvertising->start();
    return;
  }

  #if USE_DEEP_SLEEP
    delay(50);
    enterDeepSleep();
  #else
    // Aktiver Modus (für Debugging)
    delay(ADV_INTERVAL_MS);
    pAdvertising->stop();
    updateAdvertisement();
    pAdvertising->start();
  #endif
}
