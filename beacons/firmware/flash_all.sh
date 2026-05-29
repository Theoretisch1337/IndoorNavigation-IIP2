#!/usr/bin/env bash
#
# flash_all.sh
# ------------
# Sequenzielles Flashen aller InNav-Beacons mit aufsteigenden IDs.
#
# Usage:
#   cd code/beacons/firmware/
#   ./flash_all.sh [start_id] [end_id]
#
# Beispiele:
#   ./flash_all.sh         # Default: 1..8
#   ./flash_all.sh 3 5     # Nur Beacons 3, 4, 5
#
# Pro Beacon:
#   1. Skript fordert dich auf, den Beacon einzustecken
#   2. Bestätige mit Enter
#   3. PlatformIO flasht mit -D BEACON_ID=N
#   4. Verifikation via nRF Connect (Major sollte = N sein)
#

set -e

# PlatformIO ist oft nicht im Standard-PATH (nur in VS Code installiert).
# Den venv-Pfad ergänzen, damit `pio` direkt aufrufbar ist.
export PATH="$HOME/.platformio/penv/bin:$PATH"

if ! command -v pio >/dev/null 2>&1; then
  echo "FEHLER: 'pio' nicht gefunden. PlatformIO installieren oder Pfad prüfen."
  exit 1
fi

START_ID="${1:-1}"
END_ID="${2:-8}"

# Backup der originalen platformio.ini-Zeile, damit wir sie bei
# Abbruch (CTRL-C, pio-Fehler, USB nicht erkannt) wieder herstellen
# können. Sonst bleibt platformio.ini auf der zuletzt versuchten ID
# stehen und der nächste manuelle pio-run flasht die falsche ID.
ORIGINAL_LINE=$(grep -E "^\s*-D BEACON_ID=" platformio.ini || true)

restore_original() {
  if [ -n "$ORIGINAL_LINE" ]; then
    echo ""
    echo "  → Stelle ursprüngliche BEACON_ID in platformio.ini wieder her"
    # ORIGINAL_LINE wieder einsetzen (BSD- und GNU-sed kompatibel)
    sed -i.bak "s/-D BEACON_ID=[0-9]*/$(echo "$ORIGINAL_LINE" | grep -oE '\-D BEACON_ID=[0-9]+')/" platformio.ini
    rm -f platformio.ini.bak
  fi
}
trap restore_original EXIT

echo "════════════════════════════════════════════════════════"
echo "  InNav Beacon Flash-Runde: ID $START_ID bis $END_ID"
echo "════════════════════════════════════════════════════════"
echo ""

for id in $(seq "$START_ID" "$END_ID"); do
  echo ""
  echo "────────────────────────────────────────"
  echo "  Beacon #$id"
  echo "────────────────────────────────────────"
  read -r -p "  Stecke Beacon #$id per USB-C ein, dann ENTER (oder 's' zum Skippen): " answer
  if [ "$answer" = "s" ] || [ "$answer" = "S" ]; then
    echo "  → übersprungen"
    continue
  fi

  echo "  → Setze BEACON_ID=$id in platformio.ini …"
  # Patche die BEACON_ID-Zeile in platformio.ini (BSD-sed-kompatibel für macOS)
  sed -i.bak "s/-D BEACON_ID=[0-9]*/-D BEACON_ID=$id/" platformio.ini
  rm -f platformio.ini.bak

  echo "  → Flashe Beacon #$id …"
  pio run --target upload

  echo ""
  echo "  ✓ Beacon #$id geflasht. Verifikation mit nRF Connect:"
  echo "    erwarte Major = $id, Minor-Low-Byte tickt hoch (Sequenz)"
  read -r -p "  Enter für nächsten Beacon …" _
done

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Fertig! Beacons $START_ID..$END_ID sollten nun aktiv sein."
echo "════════════════════════════════════════════════════════"
