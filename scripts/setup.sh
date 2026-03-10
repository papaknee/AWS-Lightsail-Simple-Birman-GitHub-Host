#!/usr/bin/env bash
# =============================================================================
# setup.sh — Birman Host: Interactive setup wizard for deploying a Node.js,
#             React, or Next.js site to a Bitnami AWS Lightsail instance.
#
# Usage:
#   chmod +x setup.sh && ./setup.sh
#
# What this script does:
#   1. Collects configuration (app name, GitHub URL, app type, domain, port)
#   2. Saves config to ~/.birman/.env for reuse by other scripts
#   3. Deploys the app from GitHub (clone + install + build + PM2)
#   4. Optionally configures SSL + Apache reverse proxy
#   5. Optionally configures PM2 auto-start on reboot
#   6. Optionally backs up the SSL cert to an S3 bucket
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.birman"
CONFIG_FILE="$CONFIG_DIR/.env"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
divider() { echo -e "${BLUE}$(printf '─%.0s' {1..70})${NC}"; }

confirm() {
  local prompt="$1" default="${2:-y}"
  local yn_prompt
  [[ "$default" == "y" ]] && yn_prompt="[Y/n]" || yn_prompt="[y/N]"
  read -r -p "$(echo -e "${YELLOW}${prompt}${NC} ${yn_prompt} ")" answer
  answer="${answer:-$default}"
  [[ "${answer,,}" == "y" ]]
}

ask() {
  local var_name="$1" prompt="$2" default="${3:-}"
  local display_prompt
  if [[ -n "$default" ]]; then
    display_prompt="${prompt} [${default}]: "
  else
    display_prompt="${prompt}: "
  fi
  read -r -p "$(echo -e "${YELLOW}${display_prompt}${NC}")" value
  value="${value:-$default}"
  while [[ -z "$value" ]]; do
    read -r -p "$(echo -e "${RED}Required.${NC} ${display_prompt}")" value
    value="${value:-$default}"
  done
  printf -v "$var_name" '%s' "$value"
}

ask_optional() {
  local var_name="$1" prompt="$2"
  read -r -p "$(echo -e "${YELLOW}${prompt} (leave blank to skip): ${NC}")" value
  printf -v "$var_name" '%s' "${value:-}"
}

# ── Banner ────────────────────────────────────────────────────────────────────
clear
divider
echo -e "${BOLD}${CYAN}"
echo "  ██████╗ ██╗██████╗ ███╗   ███╗ █████╗ ███╗   ██╗"
echo "  ██╔══██╗██║██╔══██╗████╗ ████║██╔══██╗████╗  ██║"
echo "  ██████╔╝██║██████╔╝██╔████╔██║███████║██╔██╗ ██║"
echo "  ██╔══██╗██║██╔══██╗██║╚██╔╝██║██╔══██║██║╚██╗██║"
echo "  ██████╔╝██║██║  ██║██║ ╚═╝ ██║██║  ██║██║ ╚████║"
echo "  ╚═════╝ ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝"
echo -e "${NC}"
echo -e "  ${BOLD}AWS Lightsail Bitnami Deployment Wizard${NC}"
echo -e "  Deploy Node.js · React · Next.js from GitHub"
divider
echo ""
echo -e "  This wizard will:"
echo -e "  ${GREEN}✓${NC} Clone your GitHub repository"
echo -e "  ${GREEN}✓${NC} Install dependencies and build your app"
echo -e "  ${GREEN}✓${NC} Configure Apache SSL + reverse proxy (optional)"
echo -e "  ${GREEN}✓${NC} Set up PM2 for process management + auto-restart"
echo -e "  ${GREEN}✓${NC} Back up SSL certificates to S3 (optional)"
echo ""
divider

# ── Verify environment ────────────────────────────────────────────────────────
step "Checking environment"

if [[ ! -d /opt/bitnami ]]; then
  error "This script is designed for Bitnami instances on AWS Lightsail."
  error "/opt/bitnami was not found. Are you on the correct server?"
  exit 1
fi
success "Bitnami environment detected."

if ! command -v node &>/dev/null; then
  error "Node.js is not installed. Please use a Bitnami Node.js or LAMP instance."
  exit 1
fi
success "Node.js $(node --version) found."

if ! command -v npm &>/dev/null; then
  error "npm is not installed. Please use a Bitnami Node.js instance."
  exit 1
fi
success "npm $(npm --version) found."

# ── Collect configuration ─────────────────────────────────────────────────────
step "Configuration"
echo ""
echo -e "  ${BOLD}Provide details about your application.${NC}"
echo -e "  Press Enter to accept the default value shown in [brackets]."
echo ""

# App name (used as directory name and PM2 process name)
ask APP_NAME "App name (letters, numbers, hyphens only)" "my-app"
APP_NAME="${APP_NAME//[^a-zA-Z0-9_-]/-}"

# GitHub repository URL
echo ""
echo -e "  ${BOLD}GitHub repository URL${NC}"
echo -e "  For public repos:   ${CYAN}https://github.com/user/repo.git${NC}"
echo -e "  For private repos:  ${CYAN}https://github.com/user/repo.git${NC} (you will be asked for a token)"
ask GITHUB_URL "GitHub repository URL"

# Private repo token
echo ""
GITHUB_TOKEN=""
if confirm "Is this a private repository?"; then
  echo ""
  echo -e "  ${BOLD}GitHub Personal Access Token${NC}"
  echo -e "  Create one at: ${CYAN}https://github.com/settings/tokens${NC}"
  echo -e "  Required scopes: ${CYAN}repo${NC} (read-only is fine)"
  read -r -s -p "$(echo -e "${YELLOW}  GitHub token (input hidden): ${NC}")" GITHUB_TOKEN
  echo ""
  if [[ -z "$GITHUB_TOKEN" ]]; then
    warn "No token provided. Attempting to clone without authentication."
  fi
fi

# App type
echo ""
echo -e "  ${BOLD}Application type:${NC}"
echo -e "  1) ${CYAN}nodejs${NC}  — Express / custom Node.js server (runs on a port)"
echo -e "  2) ${CYAN}react${NC}   — Create React App or Vite (static build, served by Apache)"
echo -e "  3) ${CYAN}nextjs${NC}  — Next.js with SSR/API routes (runs on a port)"
while true; do
  read -r -p "$(echo -e "${YELLOW}  Choose [1/2/3]: ${NC}")" app_type_choice
  case "${app_type_choice}" in
    1) APP_TYPE="nodejs"; break ;;
    2) APP_TYPE="react";  break ;;
    3) APP_TYPE="nextjs"; break ;;
    "") warn "Please enter 1, 2, or 3." ;;
    *) warn "Please enter 1, 2, or 3." ;;
  esac
done

# Port (only for nodejs / nextjs)
APP_PORT=""
if [[ "$APP_TYPE" != "react" ]]; then
  default_port=3000
  [[ "$APP_TYPE" == "nextjs" ]] && default_port=3000
  ask APP_PORT "Port your app listens on" "$default_port"
fi

# Start command override
START_CMD=""
if [[ "$APP_TYPE" != "react" ]]; then
  echo ""
  echo -e "  ${BOLD}Start command${NC}"
  echo -e "  Leave blank to use ${CYAN}npm start${NC} (standard for Next.js / many Express apps)."
  echo -e "  Examples: ${CYAN}node server.js${NC}  |  ${CYAN}node index.js${NC}  |  ${CYAN}npm run serve${NC}"
  ask_optional START_CMD "Start command"
  [[ -z "$START_CMD" ]] && START_CMD="npm start"
fi

# Domain name
echo ""
echo -e "  ${BOLD}Domain name${NC}"
echo -e "  Leave blank to skip SSL/proxy setup (accessible via IP only)."
ask_optional DOMAIN "Domain name (e.g. example.com)"

# S3 bucket for SSL backup
S3_BUCKET=""
if [[ -n "$DOMAIN" ]]; then
  echo ""
  if confirm "Back up SSL certificates to an S3 bucket?"; then
    ask S3_BUCKET "S3 bucket name (e.g. my-backups)"
  fi
fi

# ── Confirm before proceeding ─────────────────────────────────────────────────
echo ""
divider
echo -e "\n  ${BOLD}Summary of your configuration:${NC}\n"
echo -e "  App name:        ${CYAN}${APP_NAME}${NC}"
echo -e "  GitHub URL:      ${CYAN}${GITHUB_URL}${NC}"
echo -e "  Private repo:    ${CYAN}$( [[ -n "$GITHUB_TOKEN" ]] && echo "Yes (token provided)" || echo "No" )${NC}"
echo -e "  App type:        ${CYAN}${APP_TYPE}${NC}"
[[ -n "$APP_PORT" ]] && echo -e "  Port:            ${CYAN}${APP_PORT}${NC}"
[[ "$APP_TYPE" != "react" ]] && echo -e "  Start command:   ${CYAN}${START_CMD}${NC}"
[[ -n "$DOMAIN" ]] && echo -e "  Domain:          ${CYAN}${DOMAIN}${NC}" || echo -e "  Domain:          ${YELLOW}(none – IP access only)${NC}"
[[ -n "$S3_BUCKET" ]] && echo -e "  S3 SSL backup:   ${CYAN}${S3_BUCKET}${NC}" || echo -e "  S3 SSL backup:   ${YELLOW}(skipped)${NC}"
echo ""

if ! confirm "Proceed with these settings?"; then
  echo "Aborted. Re-run ./setup.sh to start over."
  exit 0
fi

# ── Save configuration ────────────────────────────────────────────────────────
step "Saving configuration"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
# Birman Host configuration — generated by setup.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
APP_NAME="${APP_NAME}"
GITHUB_URL="${GITHUB_URL}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
APP_TYPE="${APP_TYPE}"
APP_PORT="${APP_PORT}"
START_CMD="${START_CMD}"
DOMAIN="${DOMAIN}"
S3_BUCKET="${S3_BUCKET}"
EOF
chmod 600 "$CONFIG_FILE"
success "Config saved to $CONFIG_FILE"

# ── Deploy ────────────────────────────────────────────────────────────────────
step "Deploying application from GitHub"
bash "$SCRIPT_DIR/deploy.sh" --config "$CONFIG_FILE"

# ── SSL + proxy setup ─────────────────────────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
  step "Setting up SSL and Apache reverse proxy"
  bash "$SCRIPT_DIR/ssl-proxy-setup.sh" --config "$CONFIG_FILE"
else
  warn "No domain configured — skipping SSL and proxy setup."
  if [[ "$APP_TYPE" != "react" ]]; then
    info "Your app is running on port ${APP_PORT}. Access it via http://<LIGHTSAIL-IP>:${APP_PORT}"
    info "Note: You may need to open port ${APP_PORT} in the Lightsail firewall."
  fi
fi

# ── PM2 auto-start ────────────────────────────────────────────────────────────
if [[ "$APP_TYPE" != "react" ]]; then
  step "Configuring PM2 auto-start on reboot"
  bash "$SCRIPT_DIR/pm2-autorun.sh" --config "$CONFIG_FILE"
fi

# ── S3 SSL backup ─────────────────────────────────────────────────────────────
if [[ -n "$S3_BUCKET" && -n "$DOMAIN" ]]; then
  step "Backing up SSL certificates to S3"
  bash "$SCRIPT_DIR/ssl-backup-s3.sh" --config "$CONFIG_FILE"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
divider
echo -e "\n  ${BOLD}${GREEN}🎉 Deployment complete!${NC}\n"

if [[ -n "$DOMAIN" ]]; then
  echo -e "  Your site is live at: ${CYAN}https://${DOMAIN}${NC}"
else
  LIGHTSAIL_IP=$(curl -s --max-time 5 http://checkip.amazonaws.com/ 2>/dev/null || echo "<YOUR-IP>")
  if [[ "$APP_TYPE" == "react" ]]; then
    echo -e "  Your site is live at: ${CYAN}http://${LIGHTSAIL_IP}${NC}"
  else
    echo -e "  Your site is running at: ${CYAN}http://${LIGHTSAIL_IP}:${APP_PORT}${NC}"
  fi
fi

echo ""
echo -e "  Useful commands:"
echo -e "  ${CYAN}pm2 status${NC}              — show running processes"
echo -e "  ${CYAN}pm2 logs ${APP_NAME}${NC}       — stream app logs"
echo -e "  ${CYAN}./scripts/update.sh${NC}     — pull latest code and redeploy"
echo ""
divider
