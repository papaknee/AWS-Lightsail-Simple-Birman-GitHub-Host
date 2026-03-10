#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Clone or update a GitHub repo, install dependencies, build if
#             needed, and start/restart the app with PM2.
#
# Usage (standalone):
#   ./deploy.sh --config ~/.birman/.env
#
# Or source the config manually:
#   APP_NAME=my-app GITHUB_URL=https://... APP_TYPE=nextjs APP_PORT=3000 \
#   START_CMD="npm start" ./deploy.sh
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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

# Validate required variables
: "${APP_NAME:?APP_NAME is required}"
: "${GITHUB_URL:?GITHUB_URL is required}"
: "${APP_TYPE:?APP_TYPE is required (nodejs|react|nextjs)}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
APP_PORT="${APP_PORT:-3000}"
START_CMD="${START_CMD:-npm start}"

# App directory
APP_DIR="$HOME/apps/${APP_NAME}"

# ── Build clone URL ───────────────────────────────────────────────────────────
# Embed the token into the HTTPS URL if provided, keeping credentials
# out of the process list by pre-constructing the URL here.
build_clone_url() {
  local url="$1" token="$2"
  if [[ -n "$token" && "$url" == https://* ]]; then
    # Insert token: https://TOKEN@github.com/...
    echo "${url/https:\/\//https:\/\/${token}@}"
  else
    echo "$url"
  fi
}

# ── Step 1: Install PM2 globally if not present ───────────────────────────────
if ! command -v pm2 &>/dev/null; then
  info "Installing PM2 globally..."
  sudo npm install -g pm2 --silent
  success "PM2 installed: $(pm2 --version)"
else
  success "PM2 already installed: $(pm2 --version)"
fi

# ── Step 2: Clone or pull the repository ─────────────────────────────────────
if [[ -d "$APP_DIR/.git" ]]; then
  info "Repository already cloned at $APP_DIR — pulling latest changes..."
  cd "$APP_DIR"

  # Update remote URL with token in case it changed
  CLONE_URL="$(build_clone_url "$GITHUB_URL" "$GITHUB_TOKEN")"
  git remote set-url origin "$CLONE_URL" 2>/dev/null || true
  git fetch --quiet origin
  git reset --hard origin/HEAD
  success "Repository updated."
else
  info "Cloning repository into $APP_DIR..."
  mkdir -p "$(dirname "$APP_DIR")"
  CLONE_URL="$(build_clone_url "$GITHUB_URL" "$GITHUB_TOKEN")"
  # Clone without printing the URL to avoid leaking the token
  git clone --quiet "$CLONE_URL" "$APP_DIR"
  success "Repository cloned."
  cd "$APP_DIR"
fi

# ── Step 3: Install npm dependencies ─────────────────────────────────────────
info "Installing npm dependencies..."
if [[ -f "package-lock.json" ]]; then
  npm ci --silent
else
  npm install --silent
fi
success "Dependencies installed."

# ── Step 4: Build (React / Next.js) ──────────────────────────────────────────
case "$APP_TYPE" in
  react)
    info "Building React application (npm run build)..."
    npm run build
    success "React build complete."

    # Determine build output directory
    BUILD_DIR=""
    if [[ -d "$APP_DIR/build" ]]; then
      BUILD_DIR="$APP_DIR/build"
    elif [[ -d "$APP_DIR/dist" ]]; then
      BUILD_DIR="$APP_DIR/dist"
    else
      error "Could not find build output directory (expected 'build' or 'dist')."
      exit 1
    fi

    # Deploy static files to Apache document root
    APACHE_HTDOCS="/opt/bitnami/apache/htdocs"
    if [[ ! -d "$APACHE_HTDOCS" ]]; then
      # Fallback for older Bitnami stacks
      APACHE_HTDOCS="/opt/bitnami/apache2/htdocs"
    fi

    info "Copying static build to $APACHE_HTDOCS ..."
    sudo rsync -a --delete "$BUILD_DIR/" "$APACHE_HTDOCS/"
    success "Static files deployed to $APACHE_HTDOCS."

    # Restart Apache so it picks up any changes
    info "Restarting Apache..."
    sudo /opt/bitnami/ctlscript.sh restart apache
    success "Apache restarted."
    ;;

  nextjs)
    info "Building Next.js application (npm run build)..."
    npm run build
    success "Next.js build complete."
    ;;

  nodejs)
    # No build step for a plain Node.js server unless the project defines one
    if npm run --list 2>/dev/null | grep -q "^  build"; then
      info "Running npm run build..."
      npm run build
      success "Build complete."
    else
      info "No build script found — skipping build step."
    fi
    ;;
esac

# ── Step 5: Start / restart via PM2 ──────────────────────────────────────────
if [[ "$APP_TYPE" == "react" ]]; then
  success "React static site deployed — no PM2 process needed."
  exit 0
fi

cd "$APP_DIR"

if pm2 describe "$APP_NAME" &>/dev/null; then
  info "PM2 process '${APP_NAME}' found — restarting..."
  pm2 restart "$APP_NAME" --update-env
  success "PM2 process restarted."
else
  info "Starting '${APP_NAME}' with PM2..."
  if [[ "$START_CMD" == "npm "* ]]; then
    # e.g. "npm start"      → pm2 start npm --name app -- start
    #      "npm run serve"  → pm2 start npm --name app -- run serve
    read -r -a npm_args <<< "${START_CMD#npm }"
    pm2 start npm --name "$APP_NAME" -- "${npm_args[@]}"
  else
    # Direct node invocation: e.g. "node server.js"
    read -r -a start_cmd_arr <<< "$START_CMD"
    pm2 start "${start_cmd_arr[@]}" --name "$APP_NAME"
  fi
  success "PM2 process '${APP_NAME}' started."
fi

# Show current PM2 status
pm2 list
