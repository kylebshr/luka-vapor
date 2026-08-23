#!/bin/bash
#
# Rotate the static egress IP of every started worker machine.
#
# Why this exists: each worker polls Dexcom/LibreLinkUp through a *machine-scoped*
# static egress IP. When Fly migrates a machine to a new host (or otherwise recreates
# the network namespace) that egress binding can silently wedge — the IP still shows as
# allocated in `fly machine egress-ip list`, but ALL outbound traffic through it times
# out. Symptom: every poll fails with NSURLErrorDomain -1001 (timeout), Axiom ingest
# fails with connectTimeout, worker telemetry goes dark in Axiom while the `app` machine
# (which has no egress IP) stays perfectly healthy. Live Activities stop updating.
#
# The fix is to release + reallocate the egress IP, which re-establishes the routing.
# This script does that for the whole worker fleet, one machine at a time, and verifies
# outbound reachability after each. See docs/scaling.md ("Wedged egress IPs").
#
# Usage:
#   ./rotate-egress-ips.sh            # rotate all started worker* machines (asks first)
#   ./rotate-egress-ips.sh -y         # no confirmation prompt
#   ./rotate-egress-ips.sh -n         # dry-run: show what would rotate, change nothing
#   ./rotate-egress-ips.sh <machine>  # rotate just one machine id
#   ./rotate-egress-ips.sh -a other-app ...
#
set -euo pipefail

APP="${FLY_APP:-luka-vapor-v2}"
ASSUME_YES=0
DRY_RUN=0
ONLY_MACHINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a) APP="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) ONLY_MACHINE="$1"; shift ;;
  esac
done

command -v fly >/dev/null || { echo "flyctl not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found" >&2; exit 1; }

# Discover started worker machines (never the `app` group — it doesn't poll).
WORKERS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && WORKERS+=("$line")
done < <(
  fly machines list --json -a "$APP" \
    | jq -r '.[] | select(.state=="started")
             | select((.config.metadata.fly_process_group // "") | startswith("worker"))
             | [.id, .config.metadata.fly_process_group] | @tsv' \
    | sort -k2
)

if [[ -n "$ONLY_MACHINE" ]]; then
  WORKERS=("$(printf '%s\n' "${WORKERS[@]}" | grep -E "^${ONLY_MACHINE}\b" || true)")
  [[ -n "${WORKERS[0]}" ]] || { echo "machine $ONLY_MACHINE is not a started worker in $APP" >&2; exit 1; }
fi

[[ ${#WORKERS[@]} -gt 0 ]] || { echo "no started worker machines found in $APP" >&2; exit 1; }

echo "App: $APP"
echo "Will rotate egress IPs for these machines:"
printf '  %s\n' "${WORKERS[@]}"

if [[ $DRY_RUN -eq 1 ]]; then echo "(dry-run: no changes made)"; exit 0; fi

if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Rotate egress IPs for ${#WORKERS[@]} machine(s)? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted"; exit 1; }
fi

# Confirm a machine can reach Dexcom + Axiom, and report its egress source IP.
# Returns 0 if both reachable. Runs entirely inside the container (only openssl needed).
probe() {
  local id="$1"
  local remote='
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
  fly ssh console -a "$APP" --machine "$id" -C "/bin/sh -c '$remote'" 2>/dev/null | grep -E 'reach|egress source' || \
    echo "  (probe unavailable — check logs manually)"
}

fail=0
for row in "${WORKERS[@]}"; do
  id="${row%%$'\t'*}"
  group="${row##*$'\t'}"
  echo
  echo "=== $group ($id) ==="
  echo "-- releasing current egress IP"
  fly machine egress-ip release  "$id" -a "$APP" --yes || true
  echo "-- allocating fresh egress IP"
  fly machine egress-ip allocate "$id" -a "$APP" --yes
  echo "-- verifying outbound (new keep-alive connections; stale ones may still 500/-1001 briefly)"
  if probe "$id" | tee /dev/stderr | grep -q 'FAIL'; then
    echo "!! $group still failing outbound — investigate before moving on" >&2
    fail=1
  fi
done

echo
echo "=== final egress allocation ==="
fly machine egress-ip list -a "$APP"

if [[ $fail -ne 0 ]]; then
  echo "One or more workers failed the reachability probe. See docs/scaling.md." >&2
  exit 1
fi
echo "All workers rotated and reachable."
