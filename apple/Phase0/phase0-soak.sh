#!/bin/bash
# Phase 0 — 24h soak harness for Anthropic data source validation (E2 criteria C2 + C3)
#
# Runs as a background process. Polls the same endpoint every 60s for ~24h, logs every
# response code + rate-limit header values + any OAuth refresh events. Writes JSONL
# entries that you can post-process at the end to confirm pass/fail.
#
# Usage:
#   nohup ./phase0-soak.sh > soak.log 2>&1 &
#   tail -f soak.log
#
# When complete (~24h), run:
#   ./phase0-summarize.sh soak.jsonl

set -u

KEYCHAIN_SERVICE="Claude Code-credentials"
ENDPOINT="https://api.anthropic.com/v1/messages"
INTERVAL_S=60
LOG_FILE="$(dirname "$0")/soak.jsonl"
DURATION_S=$((24 * 60 * 60))  # 24h

read_token() {
  local raw access
  raw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) || return 1
  access=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('claudeAiOauth', {}).get('accessToken', ''))" 2>/dev/null)
  if [ -z "$access" ]; then return 1; fi
  echo "$access"
}

probe() {
  local token="$1"
  local tmp_headers tmp_body
  tmp_headers=$(mktemp)
  tmp_body=$(mktemp)
  local http_code
  http_code=$(curl -s -o "$tmp_body" -D "$tmp_headers" -w "%{http_code}" \
    "$ENDPOINT" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/2.1.5" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')

  local now_iso server_date s5h_util s5h_reset s5h_status s7d_util s7d_reset s7d_status req_id org_id
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  server_date=$(grep -i "^date:" "$tmp_headers" | head -1 | tr -d '\r' | awk '{ for (i=2; i<=NF; i++) printf "%s ", $i; print "" }' | sed 's/ $//')
  s5h_util=$(grep -i "^anthropic-ratelimit-unified-5h-utilization:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')
  s5h_reset=$(grep -i "^anthropic-ratelimit-unified-5h-reset:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')
  s5h_status=$(grep -i "^anthropic-ratelimit-unified-5h-status:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')
  s7d_util=$(grep -i "^anthropic-ratelimit-unified-7d-utilization:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')
  s7d_reset=$(grep -i "^anthropic-ratelimit-unified-7d-reset:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')
  s7d_status=$(grep -i "^anthropic-ratelimit-unified-7d-status:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')
  req_id=$(grep -i "^request-id:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')
  org_id=$(grep -i "^anthropic-organization-id:" "$tmp_headers" | tr -d '\r' | awk '{print $2}')

  # Capture error body on non-2xx
  local body_excerpt="null"
  if [ "$http_code" != "200" ]; then
    body_excerpt=$(head -c 300 "$tmp_body" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo "\"<read-error>\"")
  fi

  rm -f "$tmp_headers" "$tmp_body"

  # Emit JSONL line — use python to build the dict cleanly via env vars
  HTTP_CODE="$http_code" \
  TS="$now_iso" \
  SERVER_DATE="$server_date" \
  S5H_UTIL="$s5h_util" \
  S5H_RESET="$s5h_reset" \
  S5H_STATUS="$s5h_status" \
  S7D_UTIL="$s7d_util" \
  S7D_RESET="$s7d_reset" \
  S7D_STATUS="$s7d_status" \
  REQ_ID="$req_id" \
  ORG_ID="$org_id" \
  BODY_EXCERPT="$body_excerpt" \
  python3 -c "
import json, os
def emptyToNone(v): return v if v else None
print(json.dumps({
  'ts': os.environ['TS'],
  'http_code': int(os.environ['HTTP_CODE']),
  'server_date': emptyToNone(os.environ['SERVER_DATE']),
  's5h_util': emptyToNone(os.environ['S5H_UTIL']),
  's5h_reset': emptyToNone(os.environ['S5H_RESET']),
  's5h_status': emptyToNone(os.environ['S5H_STATUS']),
  's7d_util': emptyToNone(os.environ['S7D_UTIL']),
  's7d_reset': emptyToNone(os.environ['S7D_RESET']),
  's7d_status': emptyToNone(os.environ['S7D_STATUS']),
  'request_id': emptyToNone(os.environ['REQ_ID']),
  'org_id': emptyToNone(os.environ['ORG_ID']),
  'body_excerpt': json.loads(os.environ['BODY_EXCERPT']) if os.environ['BODY_EXCERPT'] != 'null' else None,
}))
" >> "$LOG_FILE"
}

echo "Phase 0 soak starting at $(date)"
echo "Logging to: $LOG_FILE"
echo "Duration: ${DURATION_S}s (~24h)"
echo "Interval: ${INTERVAL_S}s"

start_ts=$(date +%s)
end_ts=$((start_ts + DURATION_S))
poll_count=0

while [ "$(date +%s)" -lt "$end_ts" ]; do
  token=$(read_token)
  if [ -z "$token" ]; then
    echo "[$(date)] FAILED to read OAuth token from Keychain — soak aborting"
    python3 -c "import json; print(json.dumps({'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'error': 'token_read_failed'}))" >> "$LOG_FILE"
    sleep "$INTERVAL_S"
    continue
  fi
  probe "$token"
  poll_count=$((poll_count + 1))
  if [ $((poll_count % 30)) -eq 0 ]; then
    echo "[$(date)] $poll_count polls completed; next in ${INTERVAL_S}s"
  fi
  sleep "$INTERVAL_S"
done

echo "Phase 0 soak complete at $(date)"
echo "Total polls: $poll_count"
echo "Summary: ./phase0-summarize.sh $LOG_FILE"
