# C2 — Zugänge & Login-Bereiche

Kurzüberblick, wer/was sich wo am C2-Server anmeldet. Drei getrennte Ebenen:

| Bereich | URL | Wer | Auth-Mechanismus |
|---|---|---|---|
| **PocketBase Admin-UI** | `/_/` | Du (Admin) | Superuser E-Mail + Passwort |
| **Dashboard** | `/` | Betrachter | aktuell **offen** (nur Lesen) · prod: Login |
| **Telemetrie-API** | `POST /api/telemetry/batch` | Mobile-App | `X-Innav-Token`-Header (optional) |

---

## 1. Admin-UI (Superuser) — der eigentliche Admin-Login

PocketBase bringt eine vollständige Admin-Oberfläche mit: Collections ansehen/
bearbeiten, Daten durchsuchen, Backups, Logs, Einstellungen.

- **URL:** `http://localhost:8090/_/` (lokal) bzw.
  `https://indoornav.theoretisch.ch/_/` (deployed)
- **Superuser anlegen** (einmalig, per CLI — es gibt keine Selbstregistrierung):

  ```bash
  cd code/c2
  ./pocketbase superuser upsert indoornav@theoretisch.ch <dein-passwort>
  ```

  Auf dem Server analog im PocketBase-Verzeichnis (`/opt/innav-c2`). Alternativ
  zeigt PocketBase beim allerersten Start einen einmaligen Einrichtungs-Link
  im Log (`/_/#/pbinstall/...`) — darüber das erste Konto im Browser anlegen.
- **Passwort vergessen / ändern:** einfach `superuser upsert` mit derselben
  E-Mail und neuem Passwort erneut ausführen.

> Diese Zugangsdaten sind die **Krone** des Systems — nur du. Nicht ins Repo,
> nicht in die App. (Liegen verschlüsselt in `pb_data/`, das ist gitignored.)

## 2. Dashboard — Betrachter

- **URL:** `http://localhost:8090/` bzw. `https://indoornav.theoretisch.ch/`
- **Aktuell:** **kein Login** — die Collections `beacons`/`telemetry` sind
  öffentlich *lesbar* (`listRule: ""`), damit das Dashboard ohne Anmeldung
  funktioniert (praktisch für Demo/Schlusspräsi). **Schreiben ist gesperrt.**
- **Für den Produktivbetrieb absichern** (3 Schritte):
  1. In der Admin-UI bei `beacons` + `telemetry` die Regeln `listRule` und
     `viewRule` von leer auf `@request.auth.id != ""` setzen.
  2. Einen App-User in der `users`-Collection anlegen (PocketBase hat dafür
     eine eingebaute Auth-Collection mit E-Mail/Passwort).
  3. Im Dashboard einen kleinen Login-Screen ergänzen
     (`pb.collection('users').authWithPassword(...)` via PocketBase-JS-SDK),
     Token im `localStorage`, Requests mit `Authorization`-Header.

  → Bewusst als Phase-2 ausgelagert (Spec 02 §2: "Single-Admin Phase 2,
  Multi-User Phase 3"), damit die Demo ohne Login-Hürde läuft.

## 3. Telemetrie-API (App → C2)

Maschine-zu-Maschine, kein interaktiver Login — die App weist sich per Header
aus:

- **Header:** `X-Innav-Token: <token>`
- **Server-Seite:** wird nur geprüft, wenn die Umgebungsvariable `INNAV_TOKEN`
  gesetzt ist (`deploy/pocketbase.service`). Ist sie leer → alle Requests
  werden akzeptiert (nur für lokale Entwicklung gedacht).
- **App-Seite:** denselben Wert als `apiToken` in
  `mobileapp/lib/services/api_service.dart` setzen.
- **Empfehlung Produktiv:** zufälligen Token erzeugen
  (`openssl rand -hex 24`), in `INNAV_TOKEN` **und** in der App hinterlegen.

---

## Produktiv-Checkliste (Login-relevant)

- [ ] Superuser `indoornav@theoretisch.ch` mit starkem Passwort angelegt
- [ ] `INNAV_TOKEN` auf dem Server gesetzt + identisch in der App
- [ ] Dashboard-Lese-Regeln auf `@request.auth.id != ""` umgestellt
- [ ] Dashboard-Login ergänzt (oder Dashboard nur über VPN/Basic-Auth erreichbar)
- [ ] HTTPS aktiv (Caddy macht das automatisch, siehe `deploy/Caddyfile`)
