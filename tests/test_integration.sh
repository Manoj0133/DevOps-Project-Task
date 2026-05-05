#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="${BASE_URL:-http://localhost:${APP_PORT:-8000}}"
RESULTS_FILE="${RESULTS_FILE:-}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

report() {
  printf '%s\n' "$*"
  if [ -n "$RESULTS_FILE" ]; then
    mkdir -p "$(dirname "$RESULTS_FILE")"
    printf '%s\n' "$*" >>"$RESULTS_FILE"
  fi
}

fail() {
  report "FAIL: $*"
  exit 1
}

pass() {
  report "PASS: $*"
}

request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local body_file="$TMP_DIR/body.json"
  local status
  local rc

  : >"$body_file"
  set +e
  if [ -n "$data" ]; then
    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X "$method" -H 'Content-Type: application/json' -d "$data" "$BASE_URL$path")"
  else
    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X "$method" "$BASE_URL$path")"
  fi
  rc=$?
  set -e

  printf '%s %s %s\n' "$rc" "$status" "$body_file"
}

assert_json_file() {
  local file="$1"
  local python_expr="$2"
  python3 - "$file" "$python_expr" <<'PY'
import json
import sys

path = sys.argv[1]
expr = sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

ns = {"data": data}
safe_builtins = {
    "any": any,
    "all": all,
    "len": len,
    "min": min,
    "max": max,
}

try:
    ok = eval(expr, {"__builtins__": safe_builtins}, ns)
except Exception as exc:
    print(exc)
    raise SystemExit(1)

if not ok:
    print("assertion failed")
    raise SystemExit(1)
PY
}

assert_status() {
  local expected="$1"
  local actual="$2"
  [ "$actual" = "$expected" ]
}

SERVICE_NAME="statuspulse-test-service-$(date -u +%Y%m%d%H%M%S)"
SERVICE_URL="https://example.com/$(date -u +%s)"
INCIDENT_TITLE="Integration test incident $(date -u +%s)"

check_health() {
  read -r rc status body < <(request GET /health)
  [ "$rc" -eq 0 ] || fail "GET /health could not be reached"
  assert_status 200 "$status" || fail "GET /health returned $status"
  assert_json_file "$body" 'data["status"] == "healthy"'
  assert_json_file "$body" '"database" in data["checks"] and "redis" in data["checks"]'
  pass "GET /health"
}

check_root() {
  read -r rc status body < <(request GET /)
  [ "$rc" -eq 0 ] || fail "GET / could not be reached"
  assert_status 200 "$status" || fail "GET / returned $status"
  assert_json_file "$body" 'data["service"] == "StatusPulse"'
  assert_json_file "$body" 'data["docs"] == "/docs" and data["health"] == "/health"'
  pass "GET /"
}

check_create_service() {
  local payload response
  payload="$(printf '{"name":"%s","url":"%s"}' "$SERVICE_NAME" "$SERVICE_URL")"
  read -r rc status body < <(request POST /services "$payload")
  [ "$rc" -eq 0 ] || fail "POST /services could not be reached"
  assert_status 201 "$status" || fail "POST /services returned $status"
  assert_json_file "$body" 'data["name"].startswith("statuspulse-test-service-")'
  pass "POST /services"
}

check_list_services() {
  read -r rc status body < <(request GET /services)
  [ "$rc" -eq 0 ] || fail "GET /services could not be reached"
  assert_status 200 "$status" || fail "GET /services returned $status"
  assert_json_file "$body" 'any(item["name"] == "'"$SERVICE_NAME"'" for item in data)'
  pass "GET /services"
}

check_duplicate_service() {
  local payload
  payload="$(printf '{"name":"%s","url":"%s"}' "$SERVICE_NAME" "$SERVICE_URL")"
  read -r rc status body < <(request POST /services "$payload")
  [ "$rc" -eq 0 ] || fail "Duplicate POST /services could not be reached"
  assert_status 409 "$status" || fail "Duplicate POST /services returned $status"
  assert_json_file "$body" 'data["detail"] == "Service already exists"'
  pass "Duplicate POST /services"
}

check_create_incident() {
  local payload
  payload="$(printf '{"service_name":"%s","title":"%s","description":"%s","severity":"major"}' "$SERVICE_NAME" "$INCIDENT_TITLE" "Created by integration test")"
  read -r rc status body < <(request POST /incidents "$payload")
  [ "$rc" -eq 0 ] || fail "POST /incidents could not be reached"
  assert_status 201 "$status" || fail "POST /incidents returned $status"
  assert_json_file "$body" 'data["status"] == "investigating"'
  pass "POST /incidents"
}

check_list_incidents() {
  read -r rc status body < <(request GET /incidents)
  [ "$rc" -eq 0 ] || fail "GET /incidents could not be reached"
  assert_status 200 "$status" || fail "GET /incidents returned $status"
  assert_json_file "$body" 'any(item["title"] == "'"$INCIDENT_TITLE"'" for item in data)'
  pass "GET /incidents"
}

main() {
  check_health
  check_root
  check_create_service
  check_list_services
  check_duplicate_service
  check_create_incident
  check_list_incidents
  pass "Integration suite completed"
}

main "$@"
