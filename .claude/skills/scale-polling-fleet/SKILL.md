---
name: scale-polling-fleet
description: Scale the Dexcom polling worker fleet up or down (add/remove shards) to manage per-IP rate limits (429s). Use when 429 rates climb, a shard is overloaded, user count grows past ~50/shard, or the user wants to add/remove polling workers or rebalance egress IPs. Covers the fly.toml change, deploy, static egress IP allocation, and Axiom verification.
---

# Scaling the Dexcom polling fleet

Polling is sharded across Fly `worker<i>` process groups, each on its own machine with a
dedicated **static egress IP**. Dexcom (behind Cloudflare) rate-limits per IP, so the goal
is to keep each worker IP's request rate low — **target ≤ ~40 users per shard** (steady
state ~1 poll/user/5min ≈ ≤ ~8 req/min/IP, a normal-household shape Dexcom tolerates).

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

## 3. Deploy

Deploys ship on merge to `main` (Fly's GitHub integration). Open a PR with the fly.toml
change and merge it — that creates the new worker machines. To deploy out of band instead:

```bash
fly deploy --ha=false -a luka-vapor-v2
```

`--ha=false` creates **one** machine per new group. Without it, Fly adds a stopped standby
per group (harmless — `auto_start_machines=false` means only the started machine polls —
but it clutters `machines list` and must be skipped when allocating egress IPs).

## 4. Allocate static egress IPs (the step no deploy does)

Egress IPs are per-machine and only exist after the machine does. For **each new worker**,
allocate one to its **started** machine:

```bash
fly machines list -a luka-vapor-v2          # note the STARTED machine ID for each new worker<i>
fly machines egress-ip allocate <started-machine-id> -a luka-vapor-v2 -y
fly machine restart <started-machine-id> -a luka-vapor-v2   # REQUIRED — see below
fly machines egress-ip list -a luka-vapor-v2   # verify one distinct IPv4 per worker
```

**Restart after allocating.** A machine that booted before its egress IP was allocated
keeps egressing from Fly's shared NAT until it reconnects. Restart it so its polls actually
leave from the static IP — and confirm via a fresh `boot` event whose `egress_ip` equals
the allocated IPv4 (see step 5), *not* the shared-NAT address the pre-allocation boot showed.

Until this runs, the new worker polls from Fly's shared NAT pool (worse reputation than
today), so do it right after the deploy. IPs persist across deploys but are released if a
machine is destroyed/recreated — re-check `egress-ip list` after any machine churn.

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
`fly machine destroy <id> --force -a luka-vapor-v2`. Their egress IPs release automatically.

## Safety rules (see docs/scaling.md for the full list)

- **Exactly one machine per worker group.** Two machines on one shard split its users
  across two IPs, defeating the stable-IP goal (the atomic claim still prevents double-polls).
- **`SHARD_COUNT` must equal the worker-group count**, indices `0..N-1`, no gaps.
- **Change groups and `SHARD_COUNT` together**; rolling-deploy skew is bounded by the
  atomic claim to a few polls from the wrong IP for a minute or two.
- Rehashing on a count change moves ~1/N of users to a different shard/IP automatically —
  no data migration, all state is in shared Redis.
