# Architektur-Entscheidungen (ADRs) — IIP2 Indoor-Navigation

Dieses Dokument hält die zentralen technischen Entscheidungen des Projekts als
**Architecture Decision Records (ADR)** fest: was wurde entschieden, warum, und
welche Alternativen wurden verworfen. Eine Kurzfassung findet sich im Bericht
(Anhang B); hier stehen Kontext, Optionen und Konsequenzen im Detail.

Reihenfolge: neueste zuerst.

---

## ADR-008 · BOOT-Taster als Aus-Schalter via Polling

**Status:** Accepted · 2026-05-29

**Context:**
Die Beacons sollen sich per Knopf ein- und ausschalten lassen, ohne den Strom
(USB-C / LiPo) physisch zu trennen. Der Seeed XIAO ESP32 C6 hat genau zwei
Taster und keinen Schiebe-Power-Switch: BOOT an GPIO9 (Strapping-Pin, gedrückt
= LOW) und RESET (Hardware-Reset). Im Normalbetrieb läuft der Beacon in einem
Deep-Sleep-Duty-Cycle (1 s Sleep, ~100 ms wach pro Advertisement).

**Constraint (Hardware):**
Auf dem ESP32-C6 sind nur GPIO0–GPIO7 RTC/LP-fähig und können den Chip aus
Deep-Sleep wecken. GPIO9 (BOOT) ist nicht RTC-fähig, ein schlafender Beacon
kann einen BOOT-Druck physikalisch nicht erkennen.

**Options:**
1. BOOT (GPIO9) als Deep-Sleep-Wake-Pin: technisch unmöglich (nicht RTC-fähig).
2. Externer Taster an einem LP-Pin (GPIO0–7) als echter Wake-Pin: funktioniert,
   bedeutet aber Lötarbeit an allen Beacons.
3. BOOT in der Wach-Phase pollen: Wird BOOT lange genug gehalten, geht der
   Beacon in einen unbefristeten Deep-Sleep (kein Timer-Wakeup) = «Aus»
   (~7 uA). Wieder-Einschalten per RESET-Taster.

**Decision:**
Option 3. BOOT = aus (Polling + unbefristeter Sleep), RESET = an. Nutzt beide
vorhandenen Taster mit klarer Rollenteilung, ohne Hardware-Modifikation.

**Consequences:**
- Positiv: keine Lötarbeit, intuitive Rollen, im Normalbetrieb nur 1
  `digitalRead` pro Wach-Zyklus (kein Akku-Impact). LED bestätigt das Abschalten.
- Negativ: BOOT muss ~2–3 s gehalten werden, weil der Beacon nur ~10 % der Zeit
  wach ist. «Aus» ist Deep-Sleep (~7 uA), kein echtes 0 uA.

**Reversibility:** Einfach (Feature hinter `POWER_BUTTON_ENABLED`).

**Related:** `code/beacons/firmware/include/config.h`, `code/beacons/firmware/src/main.cpp`

---

## ADR-007 · Akku-Stand-Messung in Phase 1 als Einschränkung dokumentiert

**Status:** Accepted (Phase 1) · 2026-05-28

**Context:**
Die Firmware liest den ADC am Pin `A0/GPIO2` und mappt die Spannung über eine
Lookup-Tabelle auf einen Akku-Prozentwert. Beim Bring-Up zeigte sich, dass der
ADC konstant ~0 V liest und 0 % übertragen wird, obwohl der LiPo geladen ist.
Ursache: Der XIAO ESP32 C6 hat keinen internen Spannungsteiler-Pfad vom Akku
zum ADC (anders als der XIAO nRF52840). GPIO2 schwebt ohne externe Schaltung.

**Options:**
1. Externen Spannungsteiler löten (2× 100 kΩ je Beacon) — ~15 Min pro Beacon.
2. Akku-Wert im Code hardcoden — unehrlich.
3. Akzeptieren und im Bericht ehrlich als bekannte Einschränkung dokumentieren,
   Fix in Phase 2.

**Decision:**
Option 3. Akku-Telemetrie ist eine Komfort-Funktion, nicht Teil der Kern-Funktion
(Positionsbestimmung). Eine ehrliche Dokumentation der Einschränkung ist einer
geschönten Demo vorzuziehen.

**Consequences:**
- Positiv: Phase-1-Demo läuft termingerecht, authentischer Engineering-Befund.
- Negativ: Akku-Stand kann in der Demo nicht gezeigt werden.

**Reversibility:** Einfach (Hardware-Mod ~15 Min pro Beacon, keine Firmware-Änderung).

**Related:** `code/beacons/firmware/include/config.h`, `code/beacons/firmware/src/main.cpp` (`readBatteryPercent`)

---

## ADR-006 · Lineare Trilateration statt Levenberg-Marquardt

**Status:** Accepted · 2026-05-28

**Context:**
Die PositionEngine muss aus N gemessenen Distanzen (RSSI → Pfadverlust) eine
2D-Position berechnen. Trilateration ist ein nichtlineares Problem (Schnittpunkt
von Kreisen); das Live-Update soll bei 1–2 Hz erfolgen.

**Options:**
1. Lineares Least-Squares mit Referenz-Beacon-Subtraktion (Foy 1976): die
   quadratischen Terme heben sich auf, ein 2×2-System wird per Cramer-Regel in
   <1 ms gelöst.
2. Levenberg-Marquardt (iterativ): genauer bei stark verrauschten Distanzen,
   aber 5–10× teurer.
3. Particle-Filter: sehr robust gegen Multipath, zwei Grössenordnungen teurer.

**Decision:**
Option 1. Ein 1-ms-Solver bei 1 Hz ist ausreichend; das RSSI-Smoothing fängt den
Genauigkeitsverlust gegenüber L-M weitgehend auf; der Code ist einfach testbar.

**Consequences:**
- Positiv: sehr schnell, transparent, mathematisch klar dokumentierbar.
- Negativ: bei stark inkonsistenten Distanzen suboptimal — wird über ein
  `confidence`-Feld (RMSE der Residuen) nach aussen kommuniziert.

**Reversibility:** Einfach (`solve` ist isoliert, ohne API-Änderung ersetzbar).

**Related:** `code/mobileapp/lib/services/position_engine.dart`, `code/mobileapp/test/position_engine_test.dart`

---

## ADR-005 · Monorepo statt Polyrepo

**Status:** Accepted · 2026-05-28

**Context:**
Das Projekt hat drei Sub-Systeme: Mobile-App (Flutter), Beacon-Firmware
(ESP32/PlatformIO), C2-Server (PocketBase).

**Options:**
1. Monorepo `code/` mit `mobileapp/`, `beacons/`, `c2/` als Unterordner.
2. Polyrepo: drei eigenständige Repos.

**Decision:**
Monorepo. Die Abgabe verlangt einen Repo-Link; atomare Commits über App + C2
sind möglich; bei einem Einzelentwickler verursacht Polyrepo nur Overhead
(3× CI, 3× README) ohne Nutzen; der Coach kann mit einem `git clone` alles sehen.

**Consequences:**
- Positiv: einfacheres Onboarding, einheitlicher Verlauf.
- Negativ: kein Per-Service-Deployment-Trigger (bei einem Einzelentwickler irrelevant).

**Reversibility:** Mittel (`git subtree split`).

**Related:** `code/QUICKSTART.md`

---

## ADR-004 · shared_preferences statt SQLite/Drift für App-Persistenz

**Status:** Accepted · 2026-05-28

**Context:**
Die Mobile-App muss Beacon-Platzierungen (Position pro Beacon-ID, Floor-ID,
optionale TX-Power-Overrides) persistieren, in Phase 2 zusätzlich die
Fingerprint-DB.

**Options:**
1. `shared_preferences` + JSON-Serialisierung (Single-Blob).
2. `sqflite` — SQL-DB mit Queries.
3. `drift` — typed SQL-Builder.

**Decision:**
`shared_preferences`. Der persistierte Zustand bleibt unter 10 KB (auch mit 50
Beacons + 100 Fingerprints); es sind keine Queries nötig (alles wird in-memory
nach Floor gefiltert); kein Migrations-Aufwand; gut inspizierbar beim Debuggen.

**Consequences:**
- Positiv: weniger Abhängigkeiten, kleinere Binary, schnelles Setup.
- Negativ: skaliert nicht für 10k+ Fingerprints — dann Migration auf `sqflite`.

**Reversibility:** Einfach (der Storage-Service ist die einzige Schnittstelle).

**Related:** `code/mobileapp/lib/services/storage.dart`

---

## ADR-003 · Gleitender Mittelwert statt Kalman-Filter für RSSI-Smoothing (Phase 1)

**Status:** Accepted (Phase 1) · 2026-05-28

**Context:**
RSSI-Werte schwanken stark (Multipath, Antennen-Orientierung, Körperdämpfung).
Glättung ist Pflicht für eine stabile Position.

**Options:**
1. Gleitender Mittelwert (Window 5 Samples ≈ 5 s bei 1 Hz).
2. Exponential-Smoothing (EMA).
3. 1D-Kalman pro Beacon-RSSI.
4. 2D-Kalman direkt auf die Position.

**Decision:**
Gleitender Mittelwert für Phase 1; Kalman im Bericht (Ausblick) als
Phase-2-Verbesserung deklariert. Bei 1 Hz ergibt Window = 5 eine Latenz von
~2.5 s (Median), akzeptabel für Indoor-Gehgeschwindigkeit. Kalman braucht
Tuning der Prozess- und Mess-Varianz und ist erst bei echter Evaluation sinnvoll.

**Consequences:**
- Positiv: trivial implementierbar, keine Hyperparameter.
- Negativ: reagiert verzögert auf schnelle Bewegungen.

**Reversibility:** Einfach (`_pushRssi` / `_mean` sind isoliert).

**Related:** `code/mobileapp/lib/services/position_engine.dart`

---

## ADR-002 · PocketBase statt klassischem Web-Framework für den C2-Server

**Status:** Accepted · 2026-05-28

**Context:**
Der C2-Server soll die Beacon-Konfiguration zentralisieren, Telemetrie sammeln,
die Fingerprint-DB hosten und ein Admin-Dashboard bieten.

**Options:**
1. Klassisches PHP/Laravel-Stack mit Postgres + Admin-Panel: mächtig, aber
   Setup im Stunden-Bereich.
2. PocketBase (Go-Single-Binary): REST + Admin-UI inklusive, SQLite eingebaut,
   Setup in Minuten.
3. Express/Node + SQLite: verworfen (nicht der bevorzugte Stack).

**Decision:**
PocketBase. Bei einem engen Zeitbudget und ohne komplexe Business-Logik (im
Kern CRUD + Append-Log) ist ein Single-Binary mit eingebautem Admin-UI optimal;
Hosting als ein Container hinter einem Reverse-Proxy.

**Consequences:**
- Positiv: Backend in wenigen Stunden produktiv, geringe Betriebskomplexität.
- Negativ: bei späterer HSLU-weiter Skalierung wäre ein vollwertiges Framework
  überlegen.

**Reversibility:** Mittel (der REST-Contract bleibt, Re-Implementation ~1–2 Tage).

**Related:** `code/c2/README.md`, `code/c2/pb_hooks/`

---

## ADR-001 · Pure Streams statt Provider/Riverpod für State-Management

**Status:** Accepted · 2026-05-28

**Context:**
Die Mobile-App hat drei Screens, die alle live BLE-Scan-Daten und
Position-Updates konsumieren.

**Options:**
1. Pure Streams + Singletons — `BleScanner` und `PositionEngine` als langlebige
   Services, Screens nutzen `StreamBuilder`.
2. `provider` — leichtgewichtiges DI.
3. `riverpod` — typed Provider-Generation.

**Decision:**
Pure Streams. Bei genau zwei Services gibt es keinen Dependency-Baum, der den
Overhead von Provider/Riverpod rechtfertigt; `StreamBuilder` ist Flutter-Standard;
die Services sind in Tests direkt mit Mocks instanziierbar.

**Consequences:**
- Positiv: keine Zusatz-Abhängigkeiten, saubere Tests.
- Negativ: bei Wachstum auf 10+ Services würde manuelles Wiring umständlich →
  dann Migration zu Riverpod.

**Reversibility:** Einfach (Provider-Wrapper um die Singletons).

**Related:** `code/mobileapp/lib/main.dart` (Service-Lifecycle), alle Screens nutzen `StreamBuilder`
