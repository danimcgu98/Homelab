#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Nano Lab — Backup Verification Script
# Runs weekly (Sunday 6:00 AM via cron)
# Verifies latest backup, sends Discord alert, auto-restores on failure
# ═══════════════════════════════════════════════════════════════

BACKUP_ROOT="/mnt/nas-backup/homelab"
LOG_FILE="/var/log/homelab-backup-verify.log"
HOSTNAME=$(hostname)

# ── LOAD SECRETS ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/secrets.env" ]; then
  source "${SCRIPT_DIR}/secrets.env"
else
  echo "WARNING: secrets.env not found at ${SCRIPT_DIR} — notifications disabled"
fi
DISCORD_WEBHOOK="${BACKUP_WEBHOOK:-}"

# Sources to verify: name|expected file or dir to check
SOURCES=(
  "saad|periods.json"
  "boggler|recipes.json"
  "collector|collector.json"
  "ledger|exists"
  "authelia|configuration.yml"
  "pihole|etc-pihole"
  "navidrome|."
  "npm|."
  "vaultwarden|db.sqlite3"
  "uptime-kuma|kuma.db"
  "portainer|portainer.db"
  "frontend|index.html"
  "calories|calories.json"
  "calendar|calendar.json"
)

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
log "Starting backup verification"

# ── CHECK NAS IS MOUNTED ──────────────────────────────────────
if ! mountpoint -q /mnt/nas-backup; then
  log "ERROR: NAS not mounted — cannot verify"
  discord 15158332 "🔴 Backup Verification Failed" "NAS is not mounted at /mnt/nas-backup. Cannot verify backups on ${HOSTNAME}."
  exit 1
fi

# ── FIND LATEST BACKUP ────────────────────────────────────────
LATEST=$(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort -r | head -1)
if [ -z "$LATEST" ]; then
  log "ERROR: No backups found in ${BACKUP_ROOT}"
  discord 15158332 "🔴 Backup Verification Failed" "No backups found at \`${BACKUP_ROOT}\` on ${HOSTNAME}."
  exit 1
fi

BACKUP_NAME=$(basename "$LATEST")
log "Verifying backup: ${BACKUP_NAME}"

# ── VERIFY EACH SOURCE ────────────────────────────────────────
PASSED=0
FAILED=0
FAILED_LIST=""
RESULTS=""

for SOURCE in "${SOURCES[@]}"; do
  IFS='|' read -r NAME CHECK <<< "$SOURCE"
  BACKUP_DIR="${LATEST}${NAME}"
  CHECK_PATH="${BACKUP_DIR}/${CHECK}"

  if [ ! -d "$BACKUP_DIR" ]; then
    log "  ✗ ${NAME}: backup directory missing"
    ((FAILED++))
    FAILED_LIST="${FAILED_LIST}${NAME}, "
    RESULTS="${RESULTS}❌ **${NAME}**: directory missing\n"
    continue
  fi

  if [ "$CHECK" = "exists" ]; then
    # Just verify the backup directory exists — contents may be empty
    log "  ✓ ${NAME}: directory exists"
    ((PASSED++))
    RESULTS="${RESULTS}✅ **${NAME}**: directory exists\n"
  elif [ "$CHECK" = "." ]; then
    # Check the directory is non-empty
    FILE_COUNT=$(find "$BACKUP_DIR" -type f | wc -l)
    if [ "$FILE_COUNT" -eq 0 ]; then
      log "  ✗ ${NAME}: backup directory is empty"
      ((FAILED++))
      FAILED_LIST="${FAILED_LIST}${NAME}, "
      RESULTS="${RESULTS}❌ **${NAME}**: directory is empty\n"
    else
      log "  ✓ ${NAME}: ${FILE_COUNT} files"
      ((PASSED++))
      RESULTS="${RESULTS}✅ **${NAME}**: ${FILE_COUNT} files\n"
    fi
  elif [ -d "${BACKUP_DIR}/${CHECK}" ]; then
    # Check is a subdirectory — verify it's non-empty
    FILE_COUNT=$(find "${BACKUP_DIR}/${CHECK}" -type f | wc -l)
    if [ "$FILE_COUNT" -eq 0 ]; then
      log "  ✗ ${NAME}: ${CHECK}/ exists but is empty"
      ((FAILED++))
      FAILED_LIST="${FAILED_LIST}${NAME}, "
      RESULTS="${RESULTS}❌ **${NAME}**: \`${CHECK}/\` is empty\n"
    else
      log "  ✓ ${NAME}: ${CHECK}/ (${FILE_COUNT} files)"
      ((PASSED++))
      RESULTS="${RESULTS}✅ **${NAME}**: \`${CHECK}/\` (${FILE_COUNT} files)\n"
    fi
  else
    if [ ! -f "$CHECK_PATH" ]; then
      log "  ✗ ${NAME}: expected file missing (${CHECK})"
      ((FAILED++))
      FAILED_LIST="${FAILED_LIST}${NAME}, "
      RESULTS="${RESULTS}❌ **${NAME}**: \`${CHECK}\` not found\n"
    elif [ ! -s "$CHECK_PATH" ]; then
      log "  ✗ ${NAME}: expected file is empty (${CHECK})"
      ((FAILED++))
      FAILED_LIST="${FAILED_LIST}${NAME}, "
      RESULTS="${RESULTS}❌ **${NAME}**: \`${CHECK}\` is empty\n"
    else
      SIZE=$(du -h "$CHECK_PATH" | cut -f1)
      log "  ✓ ${NAME}: ${CHECK} (${SIZE})"
      ((PASSED++))
      RESULTS="${RESULTS}✅ **${NAME}**: \`${CHECK}\` (${SIZE})\n"
    fi
  fi
done

log "Verification complete — ${PASSED} passed, ${FAILED} failed"

# ── SEND DISCORD NOTIFICATION ────────────────────────────────
if [ "$FAILED" -eq 0 ]; then
  discord 3066993 "✅ Backup Verified — ${BACKUP_NAME}" \
    "All **${PASSED}** sources verified successfully on \`${HOSTNAME}\`.\n\n${RESULTS}"
  log "All sources passed — Discord notified"
  log "═══════════════════════════════════════"
  exit 0
fi

# ── FAILURES — NOTIFY AND ATTEMPT AUTO-RESTORE ───────────────
FAILED_LIST="${FAILED_LIST%, }"
log "Failures detected: ${FAILED_LIST}"

discord 15158332 "🔴 Backup Verification Failed — ${BACKUP_NAME}" \
  "**${FAILED} source(s) failed** verification on \`${HOSTNAME}\`.\n\n${RESULTS}\nAttempting auto-restore from \`${BACKUP_NAME}\`..."

log "Attempting auto-restore for failed sources..."

RESTORE_SUCCESS=0
RESTORE_FAILED=0
RESTORE_RESULTS=""

restore_source() {
  local NAME="$1"
  local CONTAINER="$2"
  local DATA_PATH="$3"
  local COMPOSE_DIR="$4"
  local BACKUP_SRC="${LATEST}${NAME}"

  if [ ! -d "$BACKUP_SRC" ]; then
    log "  ✗ Cannot restore ${NAME}: backup source missing"
    ((RESTORE_FAILED++))
    RESTORE_RESULTS="${RESTORE_RESULTS}❌ **${NAME}**: backup source missing, could not restore\n"
    return
  fi

  log "  Restoring ${NAME}..."
  docker stop "$CONTAINER" 2>/dev/null || true
  rsync -a --delete "${BACKUP_SRC}/" "${DATA_PATH}/" 2>> "$LOG_FILE"
  cd "$COMPOSE_DIR" && docker compose up -d 2>/dev/null || docker start "$CONTAINER" 2>/dev/null || true
  log "  ✓ ${NAME} restored"
  ((RESTORE_SUCCESS++))
  RESTORE_RESULTS="${RESTORE_RESULTS}✅ **${NAME}**: restored from backup\n"
}

# Only restore the failed sources
IFS=', ' read -ra FAILED_NAMES <<< "$FAILED_LIST"
for NAME in "${FAILED_NAMES[@]}"; do
  case "$NAME" in
    saad)        restore_source "saad"        "saad-api"     "/home/porkchop/docker/saad-backend/data"      "/home/porkchop/docker/saad-backend" ;;
    boggler)     restore_source "boggler"     "cookbook-api" "/home/porkchop/docker/cookbook-backend/data"  "/home/porkchop/docker/cookbook-backend" ;;
    collector)   restore_source "collector"   "collector-api""/home/porkchop/docker/collector-backend/data" "/home/porkchop/docker/collector-backend" ;;
    ledger)      restore_source "ledger"      "ledger-api"   "/home/porkchop/docker/ledger-backend/data"    "/home/porkchop/docker/ledger-backend" ;;
    authelia)    restore_source "authelia"    "authelia"     "/home/porkchop/docker/authelia/config"        "/home/porkchop/docker/authelia" ;;
    pihole)      restore_source "pihole"      "pihole"       "/home/porkchop/docker/pihole-unbound/pihole"  "/home/porkchop/docker/pihole-unbound" ;;
    navidrome)   restore_source "navidrome"   "navidrome"    "/home/porkchop/docker/navidrome/data"         "/home/porkchop/docker/navidrome" ;;
    npm)         restore_source "npm"         "npm"          "/home/porkchop/docker/npm/data"               "/home/porkchop/docker/npm" ;;
    vaultwarden) restore_source "vaultwarden" "vaultwarden"  "/home/porkchop/docker/vaultwarden/data"       "/home/porkchop/docker/vaultwarden" ;;
    uptime-kuma) restore_source "uptime-kuma" "uptime-kuma"  "/home/porkchop/docker/uptime-kuma/data"       "/home/porkchop/docker/uptime-kuma" ;;
    portainer)   restore_source "portainer"   "portainer"    "/home/porkchop/docker/portainer/data"         "/home/porkchop/docker/portainer" ;;
    calories)    restore_source "calories"    "calories-api" "/home/porkchop/docker/calories-backend/data"  "/home/porkchop/docker/calories-backend" ;;
    calendar)    restore_source "calendar"    "calendar-api" "/home/porkchop/docker/calendar-backend/data"  "/home/porkchop/docker/calendar-backend" ;;
    frontend)    
      log "  Restoring frontend..."
      rsync -a --delete "${LATEST}frontend/" "/var/www/homelab/" 2>> "$LOG_FILE"
      log "  ✓ frontend restored"
      ((RESTORE_SUCCESS++))
      RESTORE_RESULTS="${RESTORE_RESULTS}✅ **frontend**: restored from backup\n"
      ;;
  esac
done

# ── SEND RESTORE RESULT ───────────────────────────────────────
if [ "$RESTORE_FAILED" -eq 0 ]; then
  discord 16776960 "🟡 Auto-Restore Complete — ${BACKUP_NAME}" \
    "Verification failed but auto-restore succeeded for all **${RESTORE_SUCCESS}** source(s) on \`${HOSTNAME}\`.\n\n**Restored:**\n${RESTORE_RESULTS}\nPlease check the services manually to confirm they are working correctly."
  log "Auto-restore complete — Discord notified"
else
  discord 15158332 "🔴 Auto-Restore Partially Failed — ${BACKUP_NAME}" \
    "Verification failed and auto-restore could not fix all issues on \`${HOSTNAME}\`.\n\n**Restore results:**\n${RESTORE_RESULTS}\n**Manual intervention required.**"
  log "Auto-restore partially failed — Discord notified"
fi

log "═══════════════════════════════════════"
