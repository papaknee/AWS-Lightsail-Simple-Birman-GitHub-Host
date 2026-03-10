#!/usr/bin/env bash
# =============================================================================
# ssl-backup-s3.sh — Back up Let's Encrypt / Bitnami SSL certificates to an
#                    Amazon S3 bucket for safekeeping.
#
# Usage (standalone):
#   ./ssl-backup-s3.sh --config ~/.birman/.env
#
# What this script does:
#   1. Ensures the AWS CLI is installed (installs it if not present)
#   2. Collects AWS credentials if not already configured
#   3. Locates your SSL certificate files
#   4. Uploads them to the specified S3 bucket under ssl-backups/<DOMAIN>/
#
# The backup can be restored by downloading the files from S3 and replacing
# the originals, then restarting Apache.
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

: "${S3_BUCKET:?S3_BUCKET is required (e.g. my-backups)}"
: "${DOMAIN:?DOMAIN is required}"

# ── Step 1: Ensure AWS CLI is installed ──────────────────────────────────────
install_aws_cli() {
  info "Installing AWS CLI v2..."
  local tmp_dir
  tmp_dir=$(mktemp -d)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o "$tmp_dir/awscliv2.zip"
  unzip -q "$tmp_dir/awscliv2.zip" -d "$tmp_dir"
  sudo "$tmp_dir/aws/install" --update
  rm -rf "$tmp_dir"
  success "AWS CLI $(aws --version 2>&1 | head -1) installed."
}

if ! command -v aws &>/dev/null; then
  install_aws_cli
else
  success "AWS CLI already installed: $(aws --version 2>&1 | head -1)"
fi

# ── Step 2: Configure AWS credentials if not present ─────────────────────────
if ! aws sts get-caller-identity &>/dev/null 2>&1; then
  echo ""
  echo -e "  ${BOLD}AWS credentials are not configured.${NC}"
  echo -e "  You will need an IAM user with S3 write permissions."
  echo -e "  Create one at: ${CYAN}https://console.aws.amazon.com/iam/home#/users${NC}"
  echo -e "  Required IAM permission: ${CYAN}s3:PutObject${NC} on arn:aws:s3:::${S3_BUCKET}/*"
  echo ""
  aws configure
fi

if ! aws sts get-caller-identity &>/dev/null 2>&1; then
  error "AWS credentials are still invalid. Please run 'aws configure' manually."
  exit 1
fi
success "AWS credentials valid."

# ── Step 3: Locate SSL certificate files ─────────────────────────────────────
find_cert_files() {
  # Check Bitnami native cert storage
  local bitnami_dir="/opt/bitnami/apache/conf/bitnami/certs"
  local le_dir="/etc/letsencrypt/live/${DOMAIN}"

  if [[ -d "$bitnami_dir" ]] && sudo test -f "${bitnami_dir}/server.crt"; then
    echo "$bitnami_dir"
    return
  elif [[ -d "$le_dir" ]] && sudo test -f "${le_dir}/fullchain.pem"; then
    echo "$le_dir"
    return
  else
    # Search for cert files in Apache config
    local conf_cert
    conf_cert=$(sudo grep -r "SSLCertificateFile" /opt/bitnami/apache/conf/ 2>/dev/null \
      | grep -v "\.bak\|#" | awk '{print $NF}' | head -1 || true)
    if [[ -n "$conf_cert" ]]; then
      dirname "$conf_cert"
      return
    fi
  fi

  echo ""
}

CERT_DIR=$(find_cert_files)
if [[ -z "$CERT_DIR" ]]; then
  error "Could not find SSL certificate directory."
  error "Run ssl-proxy-setup.sh first to obtain a certificate."
  exit 1
fi
success "Found SSL certificates in: $CERT_DIR"

# ── Step 4: Create a timestamped backup archive ───────────────────────────────
TIMESTAMP=$(date -u '+%Y%m%d-%H%M%S')
BACKUP_DIR=$(mktemp -d)
ARCHIVE_NAME="${DOMAIN}-ssl-backup-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

info "Creating backup archive..."
sudo tar -czf "$ARCHIVE_PATH" -C "$(dirname "$CERT_DIR")" "$(basename "$CERT_DIR")"
sudo chown "$(whoami)" "$ARCHIVE_PATH"
success "Archive created: $ARCHIVE_PATH"

# ── Step 5: Upload to S3 ─────────────────────────────────────────────────────
S3_KEY="ssl-backups/${DOMAIN}/${ARCHIVE_NAME}"
info "Uploading to s3://${S3_BUCKET}/${S3_KEY} ..."

aws s3 cp "$ARCHIVE_PATH" "s3://${S3_BUCKET}/${S3_KEY}" \
  --server-side-encryption AES256

success "Backup uploaded to s3://${S3_BUCKET}/${S3_KEY}"

# Clean up temp files
rm -rf "$BACKUP_DIR"

# ── Step 6: Also upload a 'latest' pointer ────────────────────────────────────
LATEST_KEY="ssl-backups/${DOMAIN}/latest-backup-name.txt"
echo "$ARCHIVE_NAME" | aws s3 cp - "s3://${S3_BUCKET}/${LATEST_KEY}"
success "Latest backup pointer updated: s3://${S3_BUCKET}/${LATEST_KEY}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}SSL certificate backup complete!${NC}"
echo ""
echo -e "  Backup location: ${CYAN}s3://${S3_BUCKET}/ssl-backups/${DOMAIN}/${ARCHIVE_NAME}${NC}"
echo ""
info "To restore: download the archive from S3 and extract it to $CERT_DIR"
info "Then restart Apache: sudo /opt/bitnami/ctlscript.sh restart apache"
echo ""

# ── Optional: Set up a cron job for weekly automatic backups ─────────────────
echo -e "  ${BOLD}Optional: Schedule automatic weekly backups${NC}"
read -r -p "$(echo -e "${YELLOW}  Add a weekly cron job for automatic SSL backups? [y/N]: ${NC}")" add_cron
if [[ "${add_cron,,}" == "y" ]]; then
  SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
  CRON_LINE="0 3 * * 0 ${SCRIPT_PATH} --config ${CONFIG_FILE} >> ${HOME}/.birman/ssl-backup.log 2>&1"

  # Add to crontab if not already present
  if crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH"; then
    info "Cron job already exists."
  else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    success "Weekly cron job added (runs every Sunday at 03:00 UTC)."
    info "View your crontab: crontab -l"
  fi
fi
