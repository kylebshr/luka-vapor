---
name: scale-polling-fleet
description: Scale the Dexcom polling worker fleet up or down (add/remove shards) to manage per-IP rate limits (429s). Use when 429 rates climb, a shard is overloaded, user count grows past ~50/shard, or the user wants to add/remove polling workers or rebalance egress IPs. Covers the fly.toml change, deploy, static egress IP allocation, and Axiom verification.
---

# Scaling the Dexcom polling fleet

Polling is sharded across Fly `worker<i>` process groups, one machine each, **each alone in
its own Fly region** with exactly one app-scoped **static egress IP** pair allocated there
(egress IPs are regional and picked at random within a region, so one-worker-per-region is
what pins a shard to one IP). Dexcom (behind Cloudflare) rate-limits per IP, so the goal
is to keep each worker IP's request rate low — **target ≤ ~40 users per shard** (steady
state ~1 poll/user/5min ≈ ≤ ~8 req/min/IP, a normal-household shape Dexcom tolerates).

Current layout: worker0=sjc (shared with the HTTP-only `app`), worker1=lax, worker2=dfw,
worker3=ord, worker4=iad, worker5=ewr. Free North American region: `yyz`. Past that, the
next step is one Fly app per shard.

Full reference: `docs/scaling.md`. This skill is the operational checklist.

## 1. Diagnose first — is it load, and is it IP-level?

Run these against the `luka-push` Axiom dataset (via the axiom MCP `queryDataset`). They
tell you whether to scale and which shard is hot.

**Per-shard 429 rate + user load (last 24h):**
```apl
['luka-push']
| where _time > ago(24h) and event == "poll"
| summarize total=count(), rate_limited=countif(status_code == "429"),
    users=dcount(user) by process_group
| extend pct_429 = round(100.0 * rate_limited / total, 2)
```

**Confirm IP-level (not account-level) on a hot shard** — many distinct users sharing the
429s on the readings endpoint = the IP is throttled; one or two repeat offenders on the
auth endpoints = an account/auth problem that scaling won't fix:
```apl
['luka-push']
| where _time > ago(24h) and event == "poll" and status_code == "429"
| summarize hits=count(), distinct_users=dcount(user) by process_group, endpoint
```

**Decide the new count**: `SHARD_COUNT = ceil(total_users / 40)`, rounded up for growth
headroom. FNV-mod hashing is not perfectly even — the heaviest shard runs ~20–30% above
average, so size for the heaviest, not the mean. Get `total_users` from the query above
(sum across shards) or `GET /activity-count`.

## 2. Edit fly.toml

Add/remove `worker<i>` groups so indices are **contiguous** `0..N-1`, and set
`SHARD_COUNT` to N — in the **same change**. Example 3 → 5:

```toml
[processes]
  app = 'serve --env production --hostname 0.0.0.0 --port 8080'
  worker0 = 'serve --env production --hostname 0.0.0.0 --port 8080'
  worker1 = 'serve --env production --hostname 0.0.0.0 --port 8080'
  worker2 = 'serve --env production --hostname 0.0.0.0 --port 8080'
  worker3 = 'serve --env production --hostname 0.0.0.0 --port 8080'
  worker4 = 'serve --env production --hostname 0.0.0.0 --port 8080'

[env]
  SHARD_COUNT = '5'
```

## 3. Allocate the new region's egress IP (before the machine exists)

Pick an unused region (`fly platform regions`; `yyz` is the remaining NA one) and
allocate its pair first — a machine created afterwards egresses from it on first boot:

```bash
fly ips allocate-egress -r <region> -a luka-vapor-v2 -y
fly ips list -a luka-vapor-v2 | grep egress      # exactly one v4 per region
```

## 4. Deploy, then move the new worker into its region

Deploys ship on merge to `main` (Fly's GitHub integration). Open a PR with the fly.toml
change and merge it — that creates the new worker machine **in `primary_region` (sjc)**,
where it shares worker0's IP until moved. To deploy out of band instead:

```bash
fly deploy --ha=false -a luka-vapor-v2
```

`--ha=false` creates **one** machine per new group. Without it, Fly adds a stopped standby
per group — **destroy standbys** (`fly machine destroy <id>`); a started one would share
its region's IP with the real worker.

Then clone the sjc machine into its region and destroy the sjc one (the clone keeps the
process-group metadata, so it boots as the right shard; the atomic claim covers the brief
overlap):

```bash
fly machines list -a luka-vapor-v2                         # sjc machine ID for worker<i>
fly machine clone <sjc-id> -r <region> -a luka-vapor-v2
fly machine destroy <sjc-id> --force -a luka-vapor-v2
./check-egress.sh                                          # region + source IP + reachability per worker
```

App-scoped IPs belong to the app, not the machine, so they survive redeploys, restarts,
and machine recreation — no re-allocation after machine churn, as long as the machine
stays in its region (in-place deploy updates preserve region).

## 5. Verify (Axiom, ~15–30 min after)

- One `boot` event per new worker with a **distinct `egress_ip`**:
  ```apl
  ['luka-push'] | where _time > ago(1h) and event == "boot"
  | project _time, process_group, machine_id, egress_ip | sort by _time desc
  ```
- `scheduler_tick` present for every shard `0..N-1` (a missing one = orphaned shard).
- Re-run the step-1 per-shard 429 query: load should be spread across N shards now, and
  the previously hot shard's `pct_429` should fall.

## Scale down

Remove the **highest-indexed** worker group(s) and lower `SHARD_COUNT` to match (contiguous
indices only — a worker whose index ≥ `SHARD_COUNT` refuses to poll and orphans nothing,
but a *gap* below the count orphans that shard). Deploy, then destroy the removed machines:
`fly machine destroy <id> --force -a luka-vapor-v2`. The region's egress IPs stay allocated
(and billed) until released: `fly ips release-egress <v4> <v6> -a luka-vapor-v2`.

## Safety rules (see docs/scaling.md for the full list)

- **Exactly one machine per worker group, and one worker per region.** A second machine
  in a region shares its IP (doubling load); a second IP pair in a region gets picked at
  random, splitting a shard's users across IPs (the atomic claim still prevents double-polls).
- **`SHARD_COUNT` must equal the worker-group count**, indices `0..N-1`, no gaps.
- **Change groups and `SHARD_COUNT` together**; rolling-deploy skew is bounded by the
  atomic claim to a few polls from the wrong IP for a minute or two.
- Rehashing on a count change moves ~1/N of users to a different shard/IP automatically —
  no data migration, all state is in shared Redis.
