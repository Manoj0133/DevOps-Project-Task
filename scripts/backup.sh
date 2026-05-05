#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
ENV_FILE="$ROOT_DIR/.env"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-7}"
S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-}"
S3_BACKUP_PREFIX="${S3_BACKUP_PREFIX:-statuspulse}"
LOG_FILE="${LOG_FILE:-$ROOT_DIR/backup.log}"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" | tee -a "$LOG_FILE"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required command: $1"
    exit 1
  }
}

[ -f "$ENV_FILE" ] || {
  log "Missing environment file: $ENV_FILE"
  exit 1
}

require_command docker
require_command gzip
require_command sort

mkdir -p "$BACKUP_DIR"

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

backup_name="statuspulse-db-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
backup_path="$BACKUP_DIR/$backup_name"

log "Creating PostgreSQL backup at $backup_path"

docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T db sh -lc \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dump -U "$POSTGRES_USER" -h 127.0.0.1 "$POSTGRES_DB"' \
  | gzip >"$backup_path"

if [ -n "$S3_BACKUP_BUCKET" ] && command -v aws >/dev/null 2>&1; then
  log "Uploading backup to s3://${S3_BACKUP_BUCKET}/${S3_BACKUP_PREFIX}/$backup_name"
  aws s3 cp "$backup_path" "s3://${S3_BACKUP_BUCKET}/${S3_BACKUP_PREFIX}/$backup_name"
fi

mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'statuspulse-db-*.sql.gz' | sort)
if [ "${#backups[@]}" -gt "$BACKUP_RETENTION_COUNT" ]; then
  delete_count=$(( ${#backups[@]} - BACKUP_RETENTION_COUNT ))
  for ((i = 0; i < delete_count; i++)); do
    log "Removing old backup ${backups[$i]}"
    rm -f "${backups[$i]}"
  done
fi

log "Backup completed successfully"
