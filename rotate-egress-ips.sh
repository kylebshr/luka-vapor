#!/bin/bash
#
# Rotate the app-scoped egress IP of the region each started worker machine lives in.
#
# Why this exists: each worker polls Dexcom/LibreLinkUp through a static egress IP. In
# the machine-scoped-IP era, a Fly host migration could silently wedge that binding — the
# IP still showed as allocated, but ALL outbound traffic through it timed out. Symptom:
# every poll fails with NSURLErrorDomain -1001 (timeout), Axiom ingest fails with
# connectTimeout, worker telemetry goes dark in Axiom. Live Activities stop updating.
# App-scoped IPs may not wedge the same way; this is the fix path if they do.
#
# For each worker: release the egress IP pair in the worker's region, allocate a fresh
# pair there, restart the machine (flushes keep-alive pools pinned to the old IP), and
# verify outbound reachability. Each worker is the only machine in its region (except
# sjc, shared with the HTTP-only `app` machine, which is restarted too).
# See docs/scaling.md ("Wedged egress IPs").
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

MACHINES_JSON=$(fly machines list --json -a "$APP")

# Started worker machines (never the `app` group — it doesn't poll): id, group, region.
WORKERS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && WORKERS+=("$line")
done < <(
  jq -r '.[] | select(.state=="started")
         | select((.config.metadata.fly_process_group // "") | startswith("worker"))
         | [.id, .config.metadata.fly_process_group, .region] | @tsv' <<<"$MACHINES_JSON" \
    | sort -k2
)

if [[ -n "$ONLY_MACHINE" ]]; then
  WORKERS=("$(printf '%s\n' "${WORKERS[@]}" | grep -E "^${ONLY_MACHINE}\b" || true)")
  [[ -n "${WORKERS[0]}" ]] || { echo "machine $ONLY_MACHINE is not a started worker in $APP" >&2; exit 1; }
fi

[[ ${#WORKERS[@]} -gt 0 ]] || { echo "no started worker machines found in $APP" >&2; exit 1; }

echo "App: $APP"
echo "Will rotate the regional egress IP for these machines:"
printf '  %s\n' "${WORKERS[@]}"

if [[ $DRY_RUN -eq 1 ]]; then echo "(dry-run: no changes made)"; exit 0; fi

if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Rotate egress IPs for ${#WORKERS[@]} machine(s)? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted"; exit 1; }
fi

# Confirm a machine can reach Dexcom + Axiom, and report its egress source IP.
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
  fly ssh console -a "$APP" --machine "$id" -C "/bin/sh -c '$remote'" </dev/null 2>/dev/null | grep -E 'reach|egress source' || \
    echo "  (probe unavailable — check logs manually)"
}

# Egress IPs (v4 + v6) currently allocated in a region.
region_egress_ips() {
  fly ips list -a "$APP" 2>/dev/null | awk -v r="$1" '$5=="egress" && $7==r {print $3}'
}

fail=0
for row in "${WORKERS[@]}"; do
  IFS=$'\t' read -r id group region <<<"$row"
  echo
  echo "=== $group ($id, $region) ==="

  # Any other started machine in this region shares the IP and needs a restart too.
  others=$(jq -r --arg r "$region" --arg id "$id" \
    '.[] | select(.state=="started" and .region==$r and .id!=$id) | .id' <<<"$MACHINES_JSON")

  old_ips=$(region_egress_ips "$region")
  if [[ -n "$old_ips" ]]; then
    echo "-- releasing $region egress IPs: $(tr '\n' ' ' <<<"$old_ips")"
    # shellcheck disable=SC2086
    fly ips release-egress $old_ips -a "$APP" || true
  else
    echo "-- no egress IP allocated in $region (worker was on shared NAT!)"
  fi
  echo "-- allocating fresh egress IP pair in $region"
  fly ips allocate-egress -r "$region" -a "$APP" --yes 2>&1 | grep -vE '^Warning|take effect' || true

  # CRITICAL: restart to flush connection pools. URLSession.shared (CGM polling) and
  # async-http-client (Axiom) both pool keep-alive connections pinned to the OLD egress
  # IP. Without a restart the app keeps reusing those now-dead connections and every
  # reuse hangs to its timeout — NSURLError -1001 on polls, connectTimeout on Axiom —
  # so a rotate-without-restart looks like it "didn't fix" the outage. See docs/scaling.md.
  echo "-- restarting $id to flush stale connection pools"
  fly machine restart "$id" -a "$APP"
  for o in $others; do
    echo "-- restarting $o (shares $region's egress IP)"
    fly machine restart "$o" -a "$APP"
  done

  echo "-- verifying outbound (allow ~30s for boot + first poll cycle)"
  sleep 15
  if probe "$id" | tee /dev/stderr | grep -q 'FAIL'; then
    echo "!! $group still failing outbound — investigate before moving on" >&2
    fail=1
  fi
done

echo
echo "=== final egress allocation ==="
fly ips list -a "$APP" | grep -E 'egress|VERSION' || true

if [[ $fail -ne 0 ]]; then
  echo "One or more workers failed the reachability probe. See docs/scaling.md." >&2
  exit 1
fi
echo "All workers rotated and reachable."
