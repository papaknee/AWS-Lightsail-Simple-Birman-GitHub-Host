#!/usr/bin/env bash
# =============================================================================
# pm2-autorun.sh — Configure PM2 to automatically start your Node.js /
#                  Next.js application whenever the server reboots.
#
# Usage (standalone):
#   ./pm2-autorun.sh --config ~/.birman/.env
#
# What this script does:
#   1. Saves the current PM2 process list to disk
#   2. Generates and runs the PM2 startup hook (so PM2 itself starts on boot)
#   3. Verifies the systemd / init.d service was created
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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
fi

APP_NAME="${APP_NAME:-my-app}"
APP_TYPE="${APP_TYPE:-nodejs}"

# ── Skip for React static sites ───────────────────────────────────────────────
if [[ "$APP_TYPE" == "react" ]]; then
  info "App type is 'react' (static build) — PM2 is not used for static sites."
  info "Apache handles serving. No autorun configuration needed."
  exit 0
fi

# ── Verify PM2 is installed and has processes ─────────────────────────────────
if ! command -v pm2 &>/dev/null; then
  error "PM2 is not installed. Run deploy.sh first to install PM2 and start the app."
  exit 1
fi

if ! pm2 describe "$APP_NAME" &>/dev/null; then
  error "PM2 process '${APP_NAME}' not found. Run deploy.sh first to start the app."
  exit 1
fi
success "PM2 process '${APP_NAME}' is running."

# ── Step 1: Save the current PM2 process list ────────────────────────────────
info "Saving PM2 process list..."
pm2 save --force
success "PM2 process list saved to ${HOME}/.pm2/dump.pm2"

# ── Step 2: Configure PM2 startup ────────────────────────────────────────────
# pm2 startup generates an OS-specific command that must be run with sudo.
# We capture that command and execute it automatically.
info "Generating PM2 startup command..."

STARTUP_OUTPUT=$(pm2 startup 2>&1 || true)
echo "$STARTUP_OUTPUT"

# Extract the sudo command from the output
# The line looks like: sudo env PATH=... pm2 startup systemd -u bitnami --hp /home/bitnami
STARTUP_CMD=$(echo "$STARTUP_OUTPUT" \
  | grep -E "^\[PM2\] \[.*\] To setup the Startup Script, copy/paste the following command" \
  -A 2 \
  | grep "sudo " \
  | head -1 \
  | xargs)

# Fallback: try extracting directly
if [[ -z "$STARTUP_CMD" ]]; then
  STARTUP_CMD=$(echo "$STARTUP_OUTPUT" | grep "^sudo " | head -1 | xargs)
fi

if [[ -z "$STARTUP_CMD" ]]; then
  warn "Could not automatically extract the startup command from PM2 output."
  warn "Please copy and run the 'sudo ...' command shown above manually."
  warn "Then run: pm2 save"
  exit 0
fi

info "Running startup command: ${STARTUP_CMD}"
# Write the pm2 startup command to a temp script and execute it to avoid
# eval with user-visible shell injection risks.
_tmp_script=$(mktemp /tmp/pm2-startup-XXXXXX.sh)
printf '#!/usr/bin/env bash\n%s\n' "$STARTUP_CMD" > "$_tmp_script"
chmod +x "$_tmp_script"
bash "$_tmp_script"
rm -f "$_tmp_script"

# ── Step 3: Save again after startup hook is registered ──────────────────────
pm2 save --force
success "PM2 process list saved."

# ── Verify the service ────────────────────────────────────────────────────────
if command -v systemctl &>/dev/null; then
  PM2_SERVICE="pm2-$(whoami)"
  if systemctl is-enabled "$PM2_SERVICE" &>/dev/null; then
    success "Systemd service '${PM2_SERVICE}' is enabled and will start on reboot."
  else
    warn "Systemd service '${PM2_SERVICE}' may not be enabled. Check: systemctl status ${PM2_SERVICE}"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}PM2 auto-start configured!${NC}"
echo ""
echo -e "  ${CYAN}${APP_NAME}${NC} will restart automatically after a reboot."
echo ""
info "Verify with: pm2 list"
info "Test reboot behaviour: sudo reboot  (then ssh back in and run 'pm2 list')"
echo ""
