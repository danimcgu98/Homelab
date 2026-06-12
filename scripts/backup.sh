#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Nano Lab — Backup Script
# Daily backup of all homelab app data to NAS
# Runs via cron at 2:00 AM, keeps last 7 backups
# Sends Discord notification on completion
# Retries failed sources once before reporting failure
# ═══════════════════════════════════════════════════════════════

BACKUP_ROOT="/mnt/nas-backup/homelab"
RETAIN=7
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
LOG_FILE="/var/log/homelab-backup.log"
HOSTNAME=$(hostname)

# ── LOAD SECRETS ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/secrets.env" ]; then
  source "${SCRIPT_DIR}/secrets.env"
else
  echo "WARNING: secrets.env not found at ${SCRIPT_DIR} — notifications disabled"
fi
DISCORD_WEBHOOK="${BACKUP_WEBHOOK:-}"

SUCCESS=0
FAILED=0
FAILED_LIST=""
RETRY_LIST=""
RESULTS=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

discord() {
  local COLOR="$1"
  local TITLE="$2"
  local MESSAGE="$3"
  [ -z "$DISCORD_WEBHOOK" ] && return 0
  curl -s -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{
      \"embeds\": [{
        \"title\": \"$TITLE\",
        \"description\": \"$MESSAGE\",
        \"color\": $COLOR,
        \"footer\": { \"text\": \"${HOSTNAME} · $(date '+%Y-%m-%d %H:%M')\" }
      }]
    }" > /dev/null
}

log "═══════════════════════════════════════"
log "Starting backup → ${BACKUP_DIR}"

# ── CHECK NAS IS MOUNTED ──────────────────────────────────────
if ! mountpoint -q /mnt/nas-backup; then
  log "ERROR: NAS is not mounted at /mnt/nas-backup. Aborting."
  discord 15158332 "🔴 Backup Failed — NAS Not Mounted" \
    "The NAS is not mounted at \`/mnt/nas-backup\` on \`${HOSTNAME}\`. No backup was taken."
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

# ── BACKUP FUNCTION ───────────────────────────────────────────
# Tries rsync, on failure deletes partial dest and retries once
backup_source() {
  local NAME="$1"
  local SRC="$2"
  local EXCLUDE="$3"
  local USE_SUDO="$4"
  local DEST="${BACKUP_DIR}/${NAME}"

  if [ ! -d "$SRC" ]; then
    log "⚠ ${NAME}: source not found (${SRC})"
    ((FAILED++))
    FAILED_LIST="${FAILED_LIST}${NAME}, "
    RESULTS="${RESULTS}❌ **${NAME}**: source directory not found\n"
    return
  fi

  mkdir -p "$DEST"

  run_rsync() {
    if [ "$USE_SUDO" = "sudo" ]; then
      sudo rsync -a --quiet $EXCLUDE "${SRC}/" "${DEST}/" 2>> "$LOG_FILE"
    elif [ -n "$EXCLUDE" ]; then
      rsync -a --quiet $EXCLUDE "${SRC}/" "${DEST}/" 2>> "$LOG_FILE"
    else
      rsync -a --quiet "${SRC}/" "${DEST}/" 2>> "$LOG_FILE"
    fi
  }

  if run_rsync; then
    log "✓ ${NAME}"
    ((SUCCESS++))
    RESULTS="${RESULTS}✅ **${NAME}**\n"
  else
    log "⚠ ${NAME}: rsync failed — deleting partial backup and retrying..."
    rm -rf "$DEST"
    mkdir -p "$DEST"
    RETRY_LIST="${RETRY_LIST}${NAME}, "

    if run_rsync; then
      log "✓ ${NAME}: retry succeeded"
      ((SUCCESS++))
      RESULTS="${RESULTS}✅ **${NAME}** _(retry succeeded)_\n"
    else
      log "✗ ${NAME}: retry also failed"
      rm -rf "$DEST"
      ((FAILED++))
      FAILED_LIST="${FAILED_LIST}${NAME}, "
      RESULTS="${RESULTS}❌ **${NAME}**: failed after retry\n"
    fi
  fi
}

# ── RUN BACKUPS ───────────────────────────────────────────────
backup_source "saad"        "/home/porkchop/docker/saad-backend/data"       ""                                   ""
backup_source "boggler"     "/home/porkchop/docker/cookbook-backend/data"   ""                                   ""
backup_source "collector"   "/home/porkchop/docker/collector-backend/data"  ""                                   ""
backup_source "ledger"      "/home/porkchop/docker/ledger-backend/data"     ""                                   ""
backup_source "authelia"    "/home/porkchop/docker/authelia/config"         ""                                   "sudo"
backup_source "pihole"      "/home/porkchop/docker/pihole-unbound/pihole"   ""                                   "sudo"
backup_source "navidrome"   "/home/porkchop/docker/navidrome/data"          "--exclude=cache/ --exclude=plugins/" ""
backup_source "npm"         "/home/porkchop/docker/npm/data"                ""                                   ""
backup_source "vaultwarden" "/home/porkchop/docker/vaultwarden/data"        ""                                   ""
backup_source "uptime-kuma" "/home/porkchop/docker/uptime-kuma/data"        ""                                   ""
backup_source "portainer"   "/home/porkchop/docker/portainer/data"          ""                                   "sudo"
backup_source "frontend"    "/var/www/homelab"                              ""                                   ""
backup_source "calories"    "/home/porkchop/docker/calories-backend/data"   ""                                   ""
backup_source "calendar"    "/home/porkchop/docker/calendar-backend/data"   ""                                   ""

# ── WRITE MANIFEST ────────────────────────────────────────────
cat > "${BACKUP_DIR}/manifest.txt" << MANIFEST
Backup: ${TIMESTAMP}
Host: ${HOSTNAME}
Sources backed up: ${SUCCESS}
Sources failed: ${FAILED}
MANIFEST

log "Backup complete — ${SUCCESS} sources backed up, ${FAILED} failed"

# ── ROTATE OLD BACKUPS ────────────────────────────────────────
BACKUP_COUNT=$(ls -1d "${BACKUP_ROOT}"/*/  2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$RETAIN" ]; then
  DELETE_COUNT=$((BACKUP_COUNT - RETAIN))
  log "Rotating — removing ${DELETE_COUNT} old backup(s)"
  ls -1d "${BACKUP_ROOT}"/*/ | sort | head -n "${DELETE_COUNT}" | while read -r OLD; do
    rm -rf "$OLD"
    log "  Deleted: $(basename $OLD)"
  done
fi

RETAINED=$(ls -1d ${BACKUP_ROOT}/*/ 2>/dev/null | wc -l)
log "Done. Backups retained: ${RETAINED}"
log "═══════════════════════════════════════"

# ── DISCORD NOTIFICATION ──────────────────────────────────────
RETRY_NOTE=""
[ -n "$RETRY_LIST" ] && RETRY_NOTE="\n\n⚠️ **Retried:** ${RETRY_LIST%, }"

if [ "$FAILED" -eq 0 ]; then
  discord 3066993 "✅ Backup Complete — ${TIMESTAMP}" \
    "All **${SUCCESS}** sources backed up successfully on \`${HOSTNAME}\`. ${RETAINED} backup(s) retained.\n\n${RESULTS}${RETRY_NOTE}"
else
  FAILED_LIST="${FAILED_LIST%, }"
  discord 15158332 "🔴 Backup Failed — ${TIMESTAMP}" \
    "**${FAILED} source(s) failed** after retry on \`${HOSTNAME}\`.\n\n${RESULTS}${RETRY_NOTE}\n\nCheck \`/var/log/homelab-backup.log\` for details."
fi
