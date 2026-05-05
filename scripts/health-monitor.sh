#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1091
  set -a
  . "$ENV_FILE"
  set +a
fi

LOG_FILE="${LOG_FILE:-/var/log/statuspulse-monitor.log}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL:-}"
if [ -z "$PUBLIC_HEALTH_URL" ]; then
  if [ -n "$PUBLIC_BASE_URL" ]; then
    PUBLIC_HEALTH_URL="${PUBLIC_BASE_URL%/}/health"
  else
    PUBLIC_HEALTH_URL="http://127.0.0.1:8000/health"
  fi
fi
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
EXPECTED_CONTAINERS="${EXPECTED_CONTAINERS:-statuspulse-caddy statuspulse-db statuspulse-redis}"
DB_CONTAINER="${DB_CONTAINER-statuspulse-db}"
DB_PORT="${DB_PORT:-5432}"
REDIS_CONTAINER="${REDIS_CONTAINER-statuspulse-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
DOMAIN="${DOMAIN:-}"
TLS_HOST="${TLS_HOST:-$DOMAIN}"
TLS_PORT="${TLS_PORT:-443}"
TLS_WARN_DAYS="${TLS_WARN_DAYS:-14}"
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
MEMORY_WARN_PCT="${MEMORY_WARN_PCT:-90}"
MONITOR_PATH="${MONITOR_PATH:-/}"
HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-10}"
WEBHOOK_TIMEOUT_SECONDS="${WEBHOOK_TIMEOUT_SECONDS:-10}"
TCP_TIMEOUT_SECONDS="${TCP_TIMEOUT_SECONDS:-3}"

if [ -n "${ACTIVE_SLOT:-}" ]; then
  case "$ACTIVE_SLOT" in
    blue) ACTIVE_CONTAINER="statuspulse-app-blue" ;;
    green) ACTIVE_CONTAINER="statuspulse-app-green" ;;
    *) ACTIVE_CONTAINER="" ;;
  esac

  if [ -n "$ACTIVE_CONTAINER" ] && ! printf '%s\n' $EXPECTED_CONTAINERS | grep -Fxq "$ACTIVE_CONTAINER"; then
    EXPECTED_CONTAINERS="$EXPECTED_CONTAINERS $ACTIVE_CONTAINER"
  fi
fi

failures=0

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

can_write_log() {
  [ -n "${LOG_FILE:-}" ] || return 1
  local log_dir
  log_dir="$(dirname "$LOG_FILE")"
  [ -d "$log_dir" ] && [ -w "$log_dir" ] && return 0
  [ -e "$LOG_FILE" ] && [ -w "$LOG_FILE" ] && return 0
  return 1
}

log_line() {
  local line
  line="[$(timestamp)] $*"
  printf '%s\n' "$line"
  if can_write_log; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

escape_json() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

send_alert() {
  local severity="$1"
  local check_name="$2"
  local message="$3"

  if [ -z "$ALERT_WEBHOOK_URL" ]; then
    log_line "ALERT [$severity] $check_name: $message"
    return 0
  fi

  if ! have_cmd curl; then
    log_line "curl is not available; cannot send webhook alert for $check_name"
    return 1
  fi

  local payload
  payload=$(printf '{"source":"statuspulse","severity":"%s","check":"%s","message":"%s","timestamp":"%s"}' \
    "$(escape_json "$severity")" \
    "$(escape_json "$check_name")" \
    "$(escape_json "$message")" \
    "$(escape_json "$(timestamp)")")

  if curl -fsS --connect-timeout "$WEBHOOK_TIMEOUT_SECONDS" --max-time "$WEBHOOK_TIMEOUT_SECONDS" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$ALERT_WEBHOOK_URL" >/dev/null; then
    log_line "Webhook delivered for $check_name"
  else
    log_line "Webhook delivery failed for $check_name"
    return 1
  fi
}

run_check() {
  local severity="$1"
  local check_name="$2"
  shift 2

  local output
  if output="$("$@")"; then
    if [ -n "$output" ]; then
      log_line "$check_name $output"
    else
      log_line "$check_name OK"
    fi
    return 0
  fi

  log_line "$check_name FAIL: $output"
  send_alert "$severity" "$check_name" "$output" || true
  failures=$((failures + 1))
  return 1
}

check_http_health() {
  if [ -z "$PUBLIC_HEALTH_URL" ]; then
    echo "PUBLIC_HEALTH_URL is not set"
    return 1
  fi

  if ! have_cmd curl; then
    echo "curl is not available"
    return 1
  fi

  if ! have_cmd python3; then
    echo "python3 is required for JSON validation"
    return 1
  fi

  local body_file http_code curl_rc json_error
  body_file="$(mktemp)" || {
    echo "unable to create a temporary file"
    return 1
  }

  http_code=$(curl -sS --connect-timeout "$HTTP_TIMEOUT_SECONDS" --max-time "$HTTP_TIMEOUT_SECONDS" \
    -o "$body_file" -w '%{http_code}' "$PUBLIC_HEALTH_URL" 2>/dev/null)
  curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    rm -f "$body_file"
    echo "curl failed for $PUBLIC_HEALTH_URL (exit $curl_rc)"
    return 1
  fi

  if [ "$http_code" != "200" ]; then
    local sample
    sample="$(head -c 160 "$body_file" | tr -d '\n')"
    rm -f "$body_file"
    if [ -n "$sample" ]; then
      echo "expected HTTP 200 from $PUBLIC_HEALTH_URL, got $http_code: $sample"
    else
      echo "expected HTTP 200 from $PUBLIC_HEALTH_URL, got $http_code"
    fi
    return 1
  fi

  json_error=$(python3 - "$body_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    print(f"invalid JSON: {exc}")
    raise SystemExit(1)

if data.get("status") != "healthy":
    print(f"status field is {data.get('status')!r}")
    raise SystemExit(1)

checks = data.get("checks", {})
for key in ("api", "database", "redis"):
    if key not in checks:
        print(f"missing checks.{key}")
        raise SystemExit(1)
PY
  )
  if [ "$?" -ne 0 ]; then
    rm -f "$body_file"
    echo "${json_error:-response body is not valid healthy JSON}"
    return 1
  fi

  rm -f "$body_file"
}

check_containers_running() {
  if [ -z "${EXPECTED_CONTAINERS// }" ]; then
    echo "SKIP (EXPECTED_CONTAINERS not set)"
    return 0
  fi

  if ! have_cmd docker; then
    echo "docker is not available"
    return 1
  fi

  local running
  if ! running="$(docker ps --format '{{.Names}}' 2>/dev/null)"; then
    echo "docker daemon is unavailable"
    return 1
  fi

  local -a missing=()
  local container
  for container in $EXPECTED_CONTAINERS; do
    if ! printf '%s\n' "$running" | grep -Fxq "$container"; then
      missing+=("$container")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "missing running containers: ${missing[*]}"
    return 1
  fi
}

container_ip() {
  local container_name="$1"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$container_name" 2>/dev/null | awk '{print $1}'
}

tcp_probe() {
  local host="$1"
  local port="$2"

  if have_cmd timeout; then
    timeout "$TCP_TIMEOUT_SECONDS" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
  else
    bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
  fi
}

check_tcp_service() {
  local label="$1"
  local container_name="$2"
  local port="$3"

  if [ -z "$container_name" ]; then
    echo "SKIP ($label container not set)"
    return 0
  fi

  if ! have_cmd docker; then
    echo "docker is not available"
    return 1
  fi

  local ip
  ip="$(container_ip "$container_name")"
  if [ -z "$ip" ]; then
    echo "unable to resolve IP for $container_name"
    return 1
  fi

  if ! tcp_probe "$ip" "$port"; then
    echo "$label is not accepting TCP connections on $ip:$port"
    return 1
  fi
}

check_db_tcp() {
  check_tcp_service "PostgreSQL" "$DB_CONTAINER" "$DB_PORT"
}

check_redis_tcp() {
  check_tcp_service "Redis" "$REDIS_CONTAINER" "$REDIS_PORT"
}

check_disk_usage() {
  if ! have_cmd df; then
    echo "df is not available"
    return 1
  fi

  local usage
  usage="$(df -P "$MONITOR_PATH" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if [ -z "$usage" ]; then
    echo "unable to read disk usage for $MONITOR_PATH"
    return 1
  fi

  if [ "$usage" -gt "$DISK_WARN_PCT" ]; then
    echo "disk usage at ${usage}% on $MONITOR_PATH exceeds ${DISK_WARN_PCT}%"
    return 1
  fi
}

check_memory_usage() {
  if ! have_cmd free; then
    echo "free is not available"
    return 1
  fi

  local total used percent
  read -r total used <<EOF
$(free -m | awk '/^Mem:/ {print $2, $3}')
EOF

  if [ -z "${total:-}" ] || [ "$total" -eq 0 ]; then
    echo "unable to read memory usage"
    return 1
  fi

  percent=$((used * 100 / total))
  if [ "$percent" -gt "$MEMORY_WARN_PCT" ]; then
    echo "memory usage at ${percent}% exceeds ${MEMORY_WARN_PCT}%"
    return 1
  fi
}

check_tls_expiry() {
  if [ -z "$TLS_HOST" ]; then
    echo "SKIP (TLS_HOST not set)"
    return 0
  fi

  if ! have_cmd openssl; then
    echo "openssl is not available"
    return 1
  fi

  local cert_file
  cert_file="$(mktemp)" || {
    echo "unable to create a temporary file"
    return 1
  }

  if ! openssl s_client -servername "$TLS_HOST" -connect "${TLS_HOST}:${TLS_PORT}" </dev/null 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/{flag=1} flag{print} /END CERTIFICATE/{exit}' >"$cert_file"; then
    rm -f "$cert_file"
    echo "unable to retrieve the certificate from ${TLS_HOST}:${TLS_PORT}"
    return 1
  fi

  if [ ! -s "$cert_file" ]; then
    rm -f "$cert_file"
    echo "no certificate data returned by ${TLS_HOST}:${TLS_PORT}"
    return 1
  fi

  if ! openssl x509 -noout -checkend "$((TLS_WARN_DAYS * 86400))" -in "$cert_file" >/dev/null 2>&1; then
    local expires
    expires="$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null | cut -d= -f2-)"
    rm -f "$cert_file"
    if [ -n "$expires" ]; then
      echo "TLS certificate for $TLS_HOST expires within ${TLS_WARN_DAYS} days (expires: $expires)"
    else
      echo "TLS certificate for $TLS_HOST expires within ${TLS_WARN_DAYS} days"
    fi
    return 1
  fi

  rm -f "$cert_file"
}

main() {
  log_line "Starting StatusPulse monitoring run"

  run_check critical "Public health" check_http_health
  run_check critical "Container presence" check_containers_running
  run_check critical "PostgreSQL TCP" check_db_tcp
  run_check critical "Redis TCP" check_redis_tcp
  run_check warning "Disk usage" check_disk_usage
  run_check warning "Memory usage" check_memory_usage
  run_check warning "TLS expiry" check_tls_expiry

  if [ "$failures" -gt 0 ]; then
    log_line "Monitoring run completed with $failures failure(s)"
    exit 1
  fi

  log_line "Monitoring run completed successfully"
}

main "$@"
