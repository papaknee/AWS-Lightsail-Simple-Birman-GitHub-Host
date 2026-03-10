#!/usr/bin/env bash
# =============================================================================
# update.sh — Pull the latest code from GitHub and redeploy.
#
# Usage:
#   ./update.sh
#   ./update.sh --config ~/.birman/.env
#
# This script re-runs deploy.sh which handles:
#   • git pull
#   • npm ci / npm install
#   • npm run build (for React / Next.js)
#   • pm2 restart (for Node.js / Next.js)
#   • rsync to Apache htdocs (for React static sites)
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# ── Load config ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CONFIG_FILE="${CONFIG_FILE:-$HOME/.birman/.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
else
  echo -e "${RED}[ERROR]${NC} Config file not found: $CONFIG_FILE"
  echo "        Run setup.sh first, or pass --config /path/to/.env"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "  ${BOLD}${CYAN}Birman Host — Update & Redeploy${NC}"
echo -e "  App: ${CYAN}${APP_NAME}${NC}  |  Type: ${CYAN}${APP_TYPE}${NC}"
echo ""
info "Starting update at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

bash "$SCRIPT_DIR/deploy.sh" --config "$CONFIG_FILE"

echo ""
success "Update complete at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
[[ "$APP_TYPE" != "react" ]] && info "View logs: pm2 logs ${APP_NAME}"
