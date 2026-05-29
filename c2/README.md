# InNav C2 — Command-&-Control-Server

Zentrales Backend + Admin-Dashboard für das InNav-Indoor-Navigationssystem.
Empfängt **Beacon-Telemetrie** (Akku, RSSI, Sequenz) von der Mobile-App und
zeigt sie live in einem Dashboard — Monitoring ausgefallener oder schwacher
Beacons auf einen Blick.

**Stack:** [PocketBase](https://pocketbase.io) (Go, Single-Binary, SQLite +
REST + Realtime) · Dashboard mit Tailwind (Play-CDN) + Lucide-Icons · **kein
Node/Bun, kein Build-Step**.

> Spec: [`.ai/specs/02-c2-server.md`](../../.ai/specs/02-c2-server.md) ·
> Domain: `indoornav.theoretisch.ch`

---

## Schnellstart (lokal)

```bash
cd code/c2/

# 1. PocketBase-Binary laden (einmalig, plattformspezifisch, nicht im Repo)
#    macOS arm64 — andere Plattformen siehe pocketbase.io/docs
curl -L -o pb.zip \
  https://github.com/pocketbase/pocketbase/releases/download/v0.39.0/pocketbase_0.39.0_darwin_arm64.zip
unzip -o pb.zip pocketbase && rm pb.zip && chmod +x pocketbase

# 2. Starten — Migrations (Collections) laufen automatisch beim ersten Start
./pocketbase serve --http=127.0.0.1:8090
```

- **Dashboard:**  http://127.0.0.1:8090/
- **REST-API:**   http://127.0.0.1:8090/api/
- **PB-Admin-UI:** http://127.0.0.1:8090/_/ (Superuser anlegen:
  `./pocketbase superuser upsert admin@theoretisch.ch <passwort>`)

Smoke-Test der Telemetrie-Pipeline:

```bash
curl -X POST http://127.0.0.1:8090/api/telemetry/batch \
  -H "Content-Type: application/json" \
  -d '{"records":[{"beaconId":11,"deviceId":"test","rssi":-67,"batteryPercent":100,"sequence":1,"ts":"2026-05-29T12:00:00.000Z"}]}'
# → {"ok":true,"saved":1}   und der Beacon erscheint im Dashboard
```

---

## Architektur

```
Mobile-App ──POST /api/telemetry/batch──► PocketBase ──► SQLite
(api_service.dart)   X-Innav-Token              │          ├─ telemetry (Log)
                     {records:[…]}              │          └─ beacons (Übersicht)
                                                │
Dashboard (pb_public/index.html) ◄──REST───────┘
   live alle 5 s: Akku-Ampel, RSSI, letzte Sicht, online/offline
```

### Collections (`pb_migrations/`)

| Collection | Zweck |
|---|---|
| `beacons` | Live-Übersicht je Beacon-ID (vom Hook upserted) — Dashboard-Quelle |
| `telemetry` | Append-only-Log aller gemeldeten Messungen (30-Tage-Cleanup) |
| `fingerprints` | RSSI-Kalibrier-Signaturen (Phase-2-Sync aus der App) |

Lesen ist öffentlich (Dashboard ohne Login), **Schreiben** läuft nur über den
Server-Hook — siehe Sicherheit.

### Endpunkte

| Methode | Pfad | Quelle |
|---|---|---|
| `GET` | `/api/health` | PocketBase (eingebaut) |
| `POST` | `/api/telemetry/batch` | **Custom-Hook** — Beacon-Telemetrie (Akku/RSSI) |
| `POST` | `/api/placements/batch` | **Custom-Hook** — Beacon-Platzierungen teilen (Sync) |
| `POST` | `/api/fingerprints/batch` | **Custom-Hook** — Fingerprints teilen (Upsert nach clientId) |
| `GET` | `/api/collections/beacons/records` | PocketBase (Dashboard + App-Pull) |
| `GET` | `/api/collections/fingerprints/records` | PocketBase (App-Pull) |
| `GET` | `/api/collections/telemetry/records` | PocketBase |

#### `POST /api/telemetry/batch`

```http
POST /api/telemetry/batch
X-Innav-Token: <token>            # nur geprüft, wenn INNAV_TOKEN gesetzt ist
Content-Type: application/json

{ "records": [
    { "beaconId": 11, "deviceId": "app-…", "rssi": -67,
      "batteryPercent": 100, "sequence": 42, "ts": "2026-05-29T12:00:00.000Z" }
] }
```

Der Hook schreibt jede Messung ins `telemetry`-Log **und** aktualisiert die
`beacons`-Übersichtszeile (lastRssi / lastBatteryPercent / lastSeenAt …) in
einer Transaktion.

---

## Deployment (Hetzner CX22 + Caddy)

Dateien in [`deploy/`](./deploy):

```bash
# einmalig auf dem VPS: PocketBase nach /opt/innav-c2, User `innav`
sudo cp deploy/pocketbase.service /etc/systemd/system/
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile
sudo systemctl enable --now pocketbase
sudo systemctl reload caddy
# Cloudflare: A-Record indoornav.theoretisch.ch → <Hetzner-IP> (Caddy macht Auto-TLS)

# danach: Updates von Migrations/Hooks/Dashboard ausrollen
./deploy/deploy.sh
```

---

## Sicherheit

- **Telemetrie-Token:** `INNAV_TOKEN` als Environment-Variable setzen
  (`pocketbase.service`). Dann lehnt `/api/telemetry/batch` Requests ohne
  passenden `X-Innav-Token` ab. In der App den gleichen Wert als `apiToken`
  setzen (`services/api_service.dart`). Ohne gesetzten Token = offen (nur Dev).
- **Lese-Regeln:** Für den Prototyp sind `beacons`/`telemetry` öffentlich
  lesbar, damit das Dashboard ohne Login funktioniert. **Produktiv** die
  `listRule`/`viewRule` auf `@request.auth.id != ""` umstellen und das
  Dashboard mit PocketBase-Auth absichern.
- Schreiben ist bereits gesperrt (nur der Server-Hook schreibt).

## Backlog / Offene Punkte

- **SMTP / Mailer einrichten** — die PocketBase-Instanz (Docker) hat aktuell
  keinen Mail-Versand. Folge: **kein E-Mail-basierter Passwort-Reset** — Accounts
  muessen per Admin-UI (`/_/`) oder CLI (`pocketbase superuser upsert`)
  zurueckgesetzt werden. Loesung: in PB unter *Settings → Mail settings* einen
  SMTP-Server hinterlegen (Transaktions-Mailer wie Postmark/Brevo/Mailgun) bzw.
  die SMTP-Zugangsdaten als Env im Compose. Danach laufen "Forgot password"-Flows.
- **Lese-Regeln haerten** — `beacons`/`telemetry`/`fingerprints` listRule auf
  `@request.auth.id != ""`, Dashboard hinter PB-Login, App-Pull ueber
  Token-Hooks (in Arbeit).
- **Deploy-Doku:** Der `deploy/`-Ordner (systemd/Bare-Metal) ist abgeloest — der
  produktive Deploy laeuft via Docker auf dem projects-Server (Caddy + PB-Container).

## Was NICHT im Repo liegt (siehe `.gitignore`)

`pocketbase` (Binary), `pb_data/` (SQLite-DB + generierte Typen), Release-Zip.
