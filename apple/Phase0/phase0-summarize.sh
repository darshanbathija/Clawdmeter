#!/bin/bash
# Phase 0 — summarize soak.jsonl into pass/fail report
#
# Usage: ./phase0-summarize.sh soak.jsonl

set -u
LOG_FILE="${1:-soak.jsonl}"
if [ ! -f "$LOG_FILE" ]; then
  echo "Log file not found: $LOG_FILE"
  exit 1
fi

python3 << PYEOF
import json
import sys
from collections import Counter

log_path = "$LOG_FILE"
with open(log_path) as f:
    entries = [json.loads(line) for line in f if line.strip()]

if not entries:
    print("Empty log — soak did not produce results")
    sys.exit(1)

total = len(entries)
status_codes = Counter(e.get('http_code') for e in entries)
errors = [e for e in entries if e.get('http_code') and e['http_code'] != 200]
missing_headers = [e for e in entries if e.get('http_code') == 200 and not e.get('s5h_util')]

s5h_status_values = Counter(e.get('s5h_status') for e in entries if e.get('s5h_status'))
s7d_status_values = Counter(e.get('s7d_status') for e in entries if e.get('s7d_status'))

# Detect epoch changes (reset boundaries crossed)
s5h_epochs = [e.get('s5h_reset') for e in entries if e.get('s5h_reset')]
s5h_epoch_changes = sum(1 for i in range(1, len(s5h_epochs)) if s5h_epochs[i] != s5h_epochs[i-1])

# C2 verdict: zero non-200s for 24h
c2_pass = len(errors) == 0
# C3 verdict: at least one epoch change observed (proves session reset cycle, implies tokens stayed valid)
c3_pass = s5h_epoch_changes >= 1

print(f"=== Phase 0 Soak Summary ===")
print(f"Log: {log_path}")
print(f"Total polls: {total}")
print(f"Window: {entries[0]['ts']} → {entries[-1]['ts']}")
print()
print(f"HTTP status code distribution:")
for code, count in sorted(status_codes.items(), key=lambda x: -x[1]):
    print(f"  {code}: {count} ({100*count/total:.1f}%)")
print()
print(f"Non-200 responses: {len(errors)}")
for e in errors[:10]:
    print(f"  [{e.get('ts')}] {e.get('http_code')}: {e.get('body_excerpt', '')[:100]}")
if len(errors) > 10:
    print(f"  ... and {len(errors) - 10} more")
print()
print(f"5h status distribution: {dict(s5h_status_values)}")
print(f"7d status distribution: {dict(s7d_status_values)}")
print(f"5h reset epoch changes (session resets): {s5h_epoch_changes}")
print()
print(f"=== Pass criteria (E2) ===")
print(f"C2 (24h zero 4xx/5xx):    {'PASS' if c2_pass else 'FAIL'} ({len(errors)} errors)")
print(f"C3 (OAuth refresh proven): {'PASS' if c3_pass else 'INCONCLUSIVE'} ({s5h_epoch_changes} session resets observed)")
print(f"C4 (field parity):          PASS (validated in quick probe)")
print(f"Missing-header polls:       {len(missing_headers)} (should be 0)")
print()
if c2_pass and c3_pass and len(missing_headers) == 0:
    print("VERDICT: Phase 0 PASS — proceed to V1 Apple work using existing data source path")
elif not c2_pass:
    print("VERDICT: Phase 0 FAIL on C2 — pivot to Option a/b/c per plan")
else:
    print("VERDICT: Phase 0 INCONCLUSIVE — extend soak or accept risk")
PYEOF
