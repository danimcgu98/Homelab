#!/bin/bash

# ── restore.sh ────────────────────────────────────────────────
# Interactive restore of homelab app data from NAS backup
# ─────────────────────────────────────────────────────────────

BACKUP_ROOT="/mnt/nas-backup/homelab"
LOG_FILE="/var/log/homelab-backup.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESTORE: $1" | tee -a "$LOG_FILE"; }

# ── APP DEFINITIONS ───────────────────────────────────────────
# Format: "display_name|container_name|data_path|compose_dir"
APPS=(
  "Saad (Period Tracker)|saad-api|/home/porkchop/docker/saad-backend/data|/home/porkchop/docker/saad-backend"
  "Boggler (Recipes)|cookbook-api|/home/porkchop/docker/cookbook-backend/data|/home/porkchop/docker/cookbook-backend"
  "Collector|collector-api|/home/porkchop/docker/collector-backend/data|/home/porkchop/docker/collector-backend"
  "Ledger (Budget)|ledger-api|/home/porkchop/docker/ledger-backend/data|/home/porkchop/docker/ledger-backend"
  "Authelia|authelia|/home/porkchop/docker/authelia/config|/home/porkchop/docker/authelia"
  "Pi-hole|pihole|/home/porkchop/docker/pihole-unbound/pihole|/home/porkchop/docker/pihole-unbound"
  "Navidrome|navidrome|/home/porkchop/docker/navidrome/data|/home/porkchop/docker/navidrome"
  "NPM|npm|/home/porkchop/docker/npm/data|/home/porkchop/docker/npm"
  "Vaultwarden|vaultwarden|/home/porkchop/docker/vaultwarden/data|/home/porkchop/docker/vaultwarden"
  "Uptime Kuma|uptime-kuma|/home/porkchop/docker/uptime-kuma/data|/home/porkchop/docker/uptime-kuma"
  "Portainer|portainer|/home/porkchop/docker/portainer/data|/home/porkchop/docker/portainer"
  "Frontend|webserver|/var/www/homelab|/home/porkchop/docker/webserver"
  "CC (Calories)|calories-api|/home/porkchop/docker/calories-backend/data|/home/porkchop/docker/calories-backend"
  "Planner (Calendar)|calendar-api|/home/porkchop/docker/calendar-backend/data|/home/porkchop/docker/calendar-backend"
)

# Backup folder keys match these names
APP_KEYS=("saad" "boggler" "collector" "ledger" "authelia" "pihole" "navidrome" "npm" "vaultwarden" "uptime-kuma" "portainer" "frontend" "calories" "calendar")

echo ""
echo -e "${BOLD}${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║      Nano Lab — Restore Tool        ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

# ── CHECK NAS ────────────────────────────────────────────────
if ! mountpoint -q /mnt/nas-backup; then
  echo -e "${RED}ERROR: NAS is not mounted at /mnt/nas-backup.${NC}"
  echo "Run: sudo mount -a"
  exit 1
fi

# ── LIST AVAILABLE BACKUPS ────────────────────────────────────
echo -e "${BOLD}Available backups:${NC}"
echo ""

BACKUPS=()
i=1
while IFS= read -r dir; do
  NAME=$(basename "$dir")
  # Show manifest if available
  if [ -f "${dir}/manifest.txt" ]; then
    SOURCES=$(grep "Sources backed up" "${dir}/manifest.txt" | cut -d: -f2 | tr -d ' ')
    echo -e "  ${CYAN}[$i]${NC} ${NAME}  (${SOURCES} sources)"
  else
    echo -e "  ${CYAN}[$i]${NC} ${NAME}"
  fi
  BACKUPS+=("$NAME")
  ((i++))
done < <(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort -r)

if [ ${#BACKUPS[@]} -eq 0 ]; then
  echo -e "${RED}No backups found in ${BACKUP_ROOT}${NC}"
  exit 1
fi

echo ""
read -p "Select backup number [1-${#BACKUPS[@]}]: " BACKUP_NUM

if ! [[ "$BACKUP_NUM" =~ ^[0-9]+$ ]] || [ "$BACKUP_NUM" -lt 1 ] || [ "$BACKUP_NUM" -gt ${#BACKUPS[@]} ]; then
  echo -e "${RED}Invalid selection.${NC}"
  exit 1
fi

SELECTED_BACKUP="${BACKUPS[$((BACKUP_NUM-1))]}"
BACKUP_DIR="${BACKUP_ROOT}/${SELECTED_BACKUP}"

echo ""
echo -e "Selected: ${BOLD}${SELECTED_BACKUP}${NC}"
echo ""

# ── SELECT APPS TO RESTORE ────────────────────────────────────
echo -e "${BOLD}Which apps do you want to restore?${NC}"
echo ""
echo -e "  ${CYAN}[0]${NC} All apps"

for j in "${!APPS[@]}"; do
  IFS='|' read -r DISPLAY _ _ _ <<< "${APPS[$j]}"
  KEY="${APP_KEYS[$j]}"
  if [ -d "${BACKUP_DIR}/${KEY}" ]; then
    echo -e "  ${CYAN}[$((j+1))]${NC} ${DISPLAY}"
  else
    echo -e "  ${CYAN}[$((j+1))]${NC} ${DISPLAY} ${YELLOW}(not in this backup)${NC}"
  fi
done

echo ""
read -p "Enter number(s) separated by spaces [e.g. 1 3 5] or 0 for all: " -a SELECTIONS

# ── BUILD RESTORE LIST ────────────────────────────────────────
RESTORE_LIST=()
if [[ " ${SELECTIONS[@]} " =~ " 0 " ]]; then
  for j in "${!APPS[@]}"; do
    RESTORE_LIST+=("$j")
  done
else
  for SEL in "${SELECTIONS[@]}"; do
    if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le ${#APPS[@]} ]; then
      RESTORE_LIST+=("$((SEL-1))")
    fi
  done
fi

if [ ${#RESTORE_LIST[@]} -eq 0 ]; then
  echo -e "${RED}No valid apps selected.${NC}"
  exit 1
fi

# ── CONFIRM ───────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}⚠  The following will be restored from ${BOLD}${SELECTED_BACKUP}${NC}${YELLOW}:${NC}"
echo ""
for idx in "${RESTORE_LIST[@]}"; do
  IFS='|' read -r DISPLAY _ _ _ <<< "${APPS[$idx]}"
  echo -e "  • ${DISPLAY}"
done
echo ""
echo -e "${RED}${BOLD}WARNING: This will overwrite current data. This cannot be undone.${NC}"
echo ""
read -p "Type 'yes' to confirm: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# ── RESTORE ───────────────────────────────────────────────────
echo ""
log "Starting restore from ${SELECTED_BACKUP}"

for idx in "${RESTORE_LIST[@]}"; do
  IFS='|' read -r DISPLAY CONTAINER DATA_PATH COMPOSE_DIR <<< "${APPS[$idx]}"
  KEY="${APP_KEYS[$idx]}"
  BACKUP_SRC="${BACKUP_DIR}/${KEY}"

  if [ ! -d "$BACKUP_SRC" ]; then
    echo -e "${YELLOW}⚠  ${DISPLAY}: not found in backup, skipping${NC}"
    log "⚠ ${KEY}: not in backup"
    continue
  fi

  echo -e "${CYAN}Restoring ${DISPLAY}...${NC}"

  # Stop container
  echo "  → Stopping ${CONTAINER}..."
  docker stop "${CONTAINER}" 2>/dev/null || true

  # Restore data
  echo "  → Copying data..."
  rsync -a --delete "${BACKUP_SRC}/" "${DATA_PATH}/" 2>> "$LOG_FILE"

  # Restart container
  echo "  → Restarting ${CONTAINER}..."
  cd "${COMPOSE_DIR}" && docker compose up -d 2>/dev/null || docker start "${CONTAINER}" 2>/dev/null || true

  echo -e "  ${GREEN}✓ ${DISPLAY} restored${NC}"
  log "✓ ${KEY} restored"
done

echo ""
echo -e "${GREEN}${BOLD}Restore complete!${NC}"
log "Restore complete from ${SELECTED_BACKUP}"
echo ""
