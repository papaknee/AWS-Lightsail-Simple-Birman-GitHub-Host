#!/usr/bin/env bash
# =============================================================================
# ssl-proxy-setup.sh — Configure Let's Encrypt SSL with Bitnami's bncert-tool
#                      and set up an Apache reverse proxy to a Node.js/Next.js
#                      application.
#
# Usage (standalone):
#   ./ssl-proxy-setup.sh --config ~/.birman/.env
#
# For React static sites (APP_TYPE=react) this script only handles SSL;
# no reverse proxy is added because Apache serves the static build directly.
#
# Prerequisites:
#   • Your domain's DNS A record must already point to this server's public IP.
#   • Ports 80 and 443 must be open in the Lightsail firewall.
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
divider() { echo -e "${CYAN}$(printf '─%.0s' {1..70})${NC}"; }

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

: "${DOMAIN:?DOMAIN is required (e.g. example.com)}"
: "${APP_TYPE:?APP_TYPE is required (nodejs|react|nextjs)}"

APP_PORT="${APP_PORT:-3000}"
APP_NAME="${APP_NAME:-my-app}"

# ── Verify DNS resolves to this machine ──────────────────────────────────────
step_dns_check() {
  info "Checking DNS resolution for ${DOMAIN}..."
  local server_ip
  server_ip=$(curl -s --max-time 10 http://checkip.amazonaws.com/ 2>/dev/null || true)
  local domain_ip
  domain_ip=$(dig +short "$DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)

  if [[ -z "$domain_ip" ]]; then
    warn "Could not resolve ${DOMAIN} via DNS. Make sure your A record points to ${server_ip:-<this-server-ip>}."
    warn "Continuing anyway — bncert-tool will perform its own check."
  elif [[ "$domain_ip" == "$server_ip" ]]; then
    success "DNS check passed: ${DOMAIN} → ${domain_ip}"
  else
    warn "DNS mismatch: ${DOMAIN} resolves to ${domain_ip} but this server's IP is ${server_ip}."
    warn "Let's Encrypt will fail if DNS is not correct. Continuing anyway."
  fi
}

step_dns_check

# ── Run bncert-tool to obtain the Let's Encrypt certificate ──────────────────
divider
echo ""
echo -e "  ${BOLD}Step 1 of 2 — Obtain SSL certificate with bncert-tool${NC}"
echo ""
echo -e "  bncert-tool is Bitnami's interactive certificate tool. It will:"
echo -e "   • Request a free Let's Encrypt certificate for ${CYAN}${DOMAIN}${NC}"
echo -e "   • Configure Apache to use HTTPS"
echo -e "   • Set up automatic HTTP→HTTPS redirect"
echo ""
echo -e "  ${BOLD}When prompted by bncert-tool:${NC}"
echo -e "   1. Enter your domain: ${CYAN}${DOMAIN}${NC}"
echo -e "      (Add www.${DOMAIN} too if you want the www variant covered)"
echo -e "   2. Provide your email address for certificate notifications"
echo -e "   3. Accept the Let's Encrypt Terms of Service"
echo -e "   4. Confirm the configuration changes"
echo ""
echo -e "  ${YELLOW}Press Enter to launch bncert-tool now...${NC}"
read -r

sudo /opt/bitnami/bncert-tool

echo ""
success "bncert-tool completed."

# ── Detect SSL certificate paths ─────────────────────────────────────────────
# bncert-tool can place certs in one of two locations depending on the Bitnami
# stack version. We detect whichever one exists.
detect_cert_paths() {
  local -n _cert_path=$1
  local -n _key_path=$2

  # Option A: Bitnami native cert storage
  local bitnami_cert="/opt/bitnami/apache/conf/bitnami/certs/server.crt"
  local bitnami_key="/opt/bitnami/apache/conf/bitnami/certs/server.key"

  # Option B: Standard Let's Encrypt path (certbot integration)
  local le_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  local le_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

  if [[ -f "$bitnami_cert" ]]; then
    _cert_path="$bitnami_cert"
    _key_path="$bitnami_key"
  elif [[ -f "$le_cert" ]]; then
    _cert_path="$le_cert"
    _key_path="$le_key"
  else
    # Search Apache config for actual paths
    local found_cert
    found_cert=$(sudo grep -r "SSLCertificateFile" /opt/bitnami/apache/conf/ 2>/dev/null \
      | grep -v "\.bak\|#" | awk '{print $NF}' | head -1 || true)
    local found_key
    found_key=$(sudo grep -r "SSLCertificateKeyFile" /opt/bitnami/apache/conf/ 2>/dev/null \
      | grep -v "\.bak\|#" | awk '{print $NF}' | head -1 || true)

    if [[ -n "$found_cert" && -f "$found_cert" ]]; then
      _cert_path="$found_cert"
      _key_path="$found_key"
    else
      error "Could not detect SSL certificate location."
      error "Expected one of:"
      error "  $bitnami_cert"
      error "  $le_cert"
      error "Check your Apache configuration manually."
      exit 1
    fi
  fi
}

SSL_CERT=""
SSL_KEY=""
detect_cert_paths SSL_CERT SSL_KEY
success "SSL certificate: $SSL_CERT"
success "SSL key:         $SSL_KEY"

# ── For React static sites: SSL-only, no proxy needed ────────────────────────
if [[ "$APP_TYPE" == "react" ]]; then
  info "App type is 'react' (static build) — SSL is configured; no reverse proxy required."
  info "Apache is serving your static files directly."
  sudo /opt/bitnami/ctlscript.sh restart apache
  success "Apache restarted with SSL."
  exit 0
fi

# ── Step 2: Configure Apache reverse proxy ────────────────────────────────────
divider
echo ""
echo -e "  ${BOLD}Step 2 of 2 — Configure Apache reverse proxy${NC}"
echo ""
info "Setting up reverse proxy: ${DOMAIN} → http://localhost:${APP_PORT}"

# Enable required Apache modules (they may already be enabled on Bitnami)
HTTPD_CONF="/opt/bitnami/apache/conf/httpd.conf"

enable_module() {
  local module="$1"
  if sudo grep -qE "^LoadModule ${module}" "$HTTPD_CONF"; then
    info "Module ${module} already enabled."
  elif sudo grep -qE "^#LoadModule ${module}" "$HTTPD_CONF"; then
    sudo sed -i "s|^#LoadModule ${module}|LoadModule ${module}|" "$HTTPD_CONF"
    success "Enabled module: ${module}"
  else
    warn "Module ${module} not found in httpd.conf — it may be compiled in or in a separate conf file."
  fi
}

enable_module "proxy_module"
enable_module "proxy_http_module"

# Ensure vhosts directory exists and is included
VHOSTS_DIR="/opt/bitnami/apache/conf/vhosts"
sudo mkdir -p "$VHOSTS_DIR"

INCLUDE_LINE="IncludeOptional conf/vhosts/*.conf"
if ! sudo grep -qF "$INCLUDE_LINE" "$HTTPD_CONF"; then
  info "Adding IncludeOptional directive to httpd.conf..."
  echo "" | sudo tee -a "$HTTPD_CONF" > /dev/null
  echo "# Birman Host — custom vhost configurations" | sudo tee -a "$HTTPD_CONF" > /dev/null
  echo "$INCLUDE_LINE" | sudo tee -a "$HTTPD_CONF" > /dev/null
  success "IncludeOptional added to httpd.conf."
fi

# Write the proxy vhost configuration file
VHOST_FILE="$VHOSTS_DIR/${APP_NAME}-proxy.conf"
info "Writing vhost config to $VHOST_FILE ..."

sudo tee "$VHOST_FILE" > /dev/null <<VHOSTCONF
# Birman Host — reverse proxy for ${APP_NAME}
# Generated on $(date -u '+%Y-%m-%dT%H:%M:%SZ')

# HTTP: redirect all traffic to HTTPS
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}

    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>

# HTTPS: reverse proxy to Node.js app on port ${APP_PORT}
<VirtualHost *:443>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}

    SSLEngine on
    SSLCertificateFile    "${SSL_CERT}"
    SSLCertificateKeyFile "${SSL_KEY}"

    # Modern TLS settings
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLHonorCipherOrder   off
    SSLSessionTickets     off

    # Reverse proxy to the Node.js / Next.js application
    ProxyPreserveHost On
    ProxyRequests     Off

    # WebSocket support (Next.js HMR, Socket.io, etc.)
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /(.*)           ws://localhost:${APP_PORT}/\$1 [P,L]

    ProxyPass        / http://localhost:${APP_PORT}/
    ProxyPassReverse / http://localhost:${APP_PORT}/

    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
</VirtualHost>
VHOSTCONF

success "Vhost config written to $VHOST_FILE"

# ── Enable mod_rewrite and mod_headers if needed ──────────────────────────────
enable_module "rewrite_module"
enable_module "headers_module"

# ── Validate Apache config then restart ──────────────────────────────────────
info "Validating Apache configuration..."
if sudo /opt/bitnami/apache/bin/httpd -t 2>&1; then
  success "Apache configuration is valid."
else
  error "Apache configuration has errors. Please check $VHOST_FILE"
  error "You can view the file with: sudo cat $VHOST_FILE"
  exit 1
fi

info "Restarting Apache..."
sudo /opt/bitnami/ctlscript.sh restart apache
success "Apache restarted."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
divider
echo -e "\n  ${BOLD}${GREEN}SSL + reverse proxy configured!${NC}"
echo -e "\n  ${CYAN}https://${DOMAIN}${NC} now proxies to your app on port ${APP_PORT}."
echo ""
info "To view Apache error logs: sudo tail -f /opt/bitnami/apache/logs/error_log"
info "To view access logs:       sudo tail -f /opt/bitnami/apache/logs/access_log"
echo ""
