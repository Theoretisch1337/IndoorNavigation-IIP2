#!/usr/bin/env bash
#
# Deployt die versionierten Teile (Migrations, Hooks, Dashboard) auf den
# Hetzner-VPS und startet PocketBase neu. Die Laufzeit-DB (pb_data/) und das
# Binary bleiben auf dem Server unangetastet.
#
# Voraussetzungen: SSH-Zugang als `innav`, PocketBase liegt in /opt/innav-c2.
# Aufruf:  ./deploy/deploy.sh
set -euo pipefail

HOST="${INNAV_C2_HOST:-innav@iip2.theoretisch.ch}"
REMOTE_DIR="/opt/innav-c2"
LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "→ Sync pb_migrations / pb_hooks / pb_public nach $HOST:$REMOTE_DIR"
rsync -avz --delete "$LOCAL_DIR/pb_migrations/" "$HOST:$REMOTE_DIR/pb_migrations/"
rsync -avz --delete "$LOCAL_DIR/pb_hooks/"      "$HOST:$REMOTE_DIR/pb_hooks/"
rsync -avz --delete "$LOCAL_DIR/pb_public/"     "$HOST:$REMOTE_DIR/pb_public/"

echo "→ PocketBase neu starten (Migrations laufen automatisch beim Start)"
ssh "$HOST" 'sudo systemctl restart pocketbase'

echo "→ Health-Check"
sleep 2
curl -fsS https://iip2.theoretisch.ch/api/health && echo "  ✓ C2 ist gesund"
