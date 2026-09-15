#!/bin/bash
#
# Print every started worker's region, actual egress source IP, and reachability to
# Dexcom + Axiom, plus the app-scoped egress IP allocated per region. Use it to confirm
# the one-worker-per-region / one-IP-per-region invariant (docs/scaling.md) and to spot a
# wedged IP (reach ... FAIL). Read-only.
#
# Usage: ./check-egress.sh [-a app]
#
set -euo pipefail

APP="${FLY_APP:-luka-vapor-v2}"
[[ "${1:-}" == "-a" ]] && APP="$2"

command -v fly >/dev/null || { echo "flyctl not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found" >&2; exit 1; }

PROBE='
for t in share2.dexcom.com:443 api.axiom.co:443; do
  if echo Q | timeout 12 openssl s_client -connect "$t" -servername "${t%:*}" -brief >/dev/null 2>&1; then
    echo "  reach ${t%:*}: OK"
  else
    echo "  reach ${t%:*}: FAIL"
  fi
done
ip=$(printf "GET /?format=text HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n" \
     | timeout 12 openssl s_client -quiet -connect api.ipify.org:443 -servername api.ipify.org 2>/dev/null | tail -1)
echo "  egress source IP: ${ip:-unknown}"
'

echo "App: $APP"
echo "Allocated app-scoped egress IPv4 per region:"
fly ips list -a "$APP" 2>/dev/null | awk '$1=="v4" && $5=="egress" {printf "  %-4s %s\n", $7, $3}' | sort
echo

fail=0
while IFS=$'\t' read -r id group region; do
  [[ -n "$id" ]] || continue
  echo "=== $group ($id, $region) ==="
  out=$(fly ssh console -a "$APP" --machine "$id" -C "/bin/sh -c '$PROBE'" </dev/null 2>/dev/null | grep -E 'reach|egress source' || true)
  [[ -n "$out" ]] && echo "$out" || echo "  (probe unavailable)"
  grep -q FAIL <<<"$out" && fail=1
done < <(
  fly machines list --json -a "$APP" \
    | jq -r '.[] | select(.state=="started")
             | select((.config.metadata.fly_process_group // "") | startswith("worker"))
             | [.id, .config.metadata.fly_process_group, .region] | @tsv' \
    | sort -k2
)

[[ $fail -eq 0 ]] || { echo; echo "One or more workers failed the reachability probe — see docs/scaling.md (Wedged egress IPs)." >&2; exit 1; }
