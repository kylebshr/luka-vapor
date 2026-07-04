# Scaling the polling fleet

## How polling is distributed

All Dexcom polling is sharded across dedicated worker machines, each with its own
**static egress IP**, so Dexcom sees a handful of low-volume IPs instead of one busy one
(their rate limiting is per-IP; see the plan/discussion in the PR that introduced this).

- The `app` process group serves HTTP only — it never polls, and its egress IP never
  touches Dexcom.
- Each `worker<i>` process group runs the scheduler for shard `i` of `SHARD_COUNT`.
  A worker only claims schedule members whose stable FNV-1a username hash mod
  `SHARD_COUNT` equals its index (`Sources/LukaVapor/Sharding/Sharding.swift`).
- The shard index comes from Fly's `FLY_PROCESS_GROUP` env var (`worker2` → shard 2);
  `SHARD_COUNT` is the one shared value, set in `fly.toml` under `[env]`.
- All state stays in the shared Redis — nothing is shard-local, so re-sharding needs no
  data migration. Changing `SHARD_COUNT` from N to M just remaps ~1/N of usernames to a
  different worker (and therefore a different egress IP).
- Due-session pickup is an atomic Lua claim (`LiveActivityPollKeys.claimDueSessions`), so
  even with misconfigured or deploy-skewed overlapping workers, a session is never polled
  twice for the same due window.

Keep **~30–50 users per worker IP**. At a steady ~1 poll per user per 5 minutes that's
≤ ~10 requests/min/IP — the traffic shape of a normal household, which Dexcom tolerates
indefinitely. Check the current session count at `GET /activity-count`.

## Scale up (add a worker)

Example: going from 3 workers to 4.

1. In `fly.toml`, add the new process group and bump the count — both in one change:

   ```toml
   [processes]
     worker3 = 'serve --env production --hostname 0.0.0.0 --port 8080'

   [env]
     SHARD_COUNT = '4'
   ```

2. Deploy and scale the new group to exactly one machine:

   ```bash
   fly deploy
   fly scale count worker3=1 -a luka-vapor-v2 -y
   ```

3. Allocate the new worker's static egress IP and verify every worker has one:

   ```bash
   fly machines list -a luka-vapor-v2                       # find worker3's machine ID
   fly machines egress-ip allocate <machine-id> -a luka-vapor-v2
   fly machines egress-ip list -a luka-vapor-v2             # one distinct IP per worker
   ```

4. Verify in logs/Axiom (see “Verifying a change” below).

## Scale down (remove a worker)

Example: going from 4 workers back to 3. Remove the **highest-indexed** group so the
remaining indices stay contiguous (`worker0..worker2` for `SHARD_COUNT = 3`) — a worker
whose index ≥ `SHARD_COUNT` refuses to poll.

1. In `fly.toml`, delete the `worker3` line and set `SHARD_COUNT = '3'`.
2. Deploy, then destroy the group's machine:

   ```bash
   fly deploy
   fly scale count worker3=0 -a luka-vapor-v2 -y
   ```

3. The destroyed machine's egress IP is released automatically. Re-check the survivors —
   machine recreation can silently drop an egress IP, reverting that worker to shared NAT:

   ```bash
   fly machines egress-ip list -a luka-vapor-v2
   ```

Sessions previously owned by the removed shard are re-owned by the remaining workers on
their next due tick (rehash) — no manual migration, worst case a few minutes of delayed
polls during the deploy.

## Deploys triggered from GitHub merges

Merge-triggered `fly deploy` handles almost everything: process groups and `SHARD_COUNT`
come from the repo's `fly.toml`, new worker groups get one machine each created
automatically, and existing machines are updated **in place** — which preserves their
static egress IPs. Ordinary merges therefore need no manual follow-up.

The exception is **egress IP allocation, which no deploy can do** — it's tied to machine
IDs that only exist after the deploy creates the machine. After the first deploy that
introduces sharding, and after any deploy that adds a worker group, run the allocate
commands from "Scale up" above. Until then the new worker polls from Fly's *shared*
egress pool (the worst IP reputation), so don't leave it long. Likewise, if Fly ever
recreates a machine (host migration, scale down/up), its egress IP is released — a
periodic `fly machines egress-ip list` check, or an Axiom alert on a `boot` event whose
`egress_ip` changed, catches this.

When a merge *removes* a worker group, verify the machine is actually gone
(`fly machines list`) and scale it to zero if it lingers.

## Rules that keep this safe

- **Exactly one machine per worker group.** `fly scale count worker1=2` would put two
  machines on the same shard; the atomic claim prevents double-polling, but the shard's
  users would alternate between two egress IPs, defeating the stable-IP goal.
- **`SHARD_COUNT` must equal the number of worker groups**, and worker indices must be
  `0..SHARD_COUNT-1` with no gaps. A gap means an orphaned shard: those users' schedule
  entries stay due, their activities go stale, and their Redis hashes self-expire after
  the 8h backstop TTL.
- **Change `[processes]` and `SHARD_COUNT` in the same deploy.** During the rolling
  deploy old and new machines briefly disagree on the count; the atomic claim bounds the
  damage to a few polls landing from the "wrong" IP for a couple of minutes.
- `auto_start_machines = false`, so a **stopped** worker stays stopped and orphans its
  shard until restarted (`fly machines start <id>`). Crashed machines are restarted by
  Fly automatically.

## Rollback to single-process mode

Revert `fly.toml` to no `[processes]` section (or just an `app` group) and **remove
`SHARD_COUNT` from `[env]`**, then:

```bash
fly deploy
fly scale count worker0=0 worker1=0 worker2=0 -a luka-vapor-v2 -y
```

With `SHARD_COUNT` unset the process falls back to legacy mode — shard (0, 1) — and the
single `app` machine polls everything from its own IP again, exactly the pre-sharding
behavior. This is also how local dev runs.

## Verifying a change

1. **Logs**: each worker logs `Scheduler enabled for shard i/N` on boot; the app machine
   logs `Scheduler disabled (HTTP-only process)`.
2. **Axiom** (all events carry `machine_id`, `process_group`, `shard` automatically):
   - one `boot` event per machine with a distinct `egress_ip` per worker;
   - `scheduler_tick` present for every shard `0..N-1` (a shard with no beats for
     >2 minutes is down or orphaned — this is the alert to set);
   - `poll` events per shard sum to roughly the pre-change total
     (≈ session count / 300 per second).
3. **The payoff metric**: fraction of `poll` events with `status_code == "429"`, grouped
   by `shard` / `egress_ip`. Scale up when a shard's 429 rate climbs or its user share
   exceeds ~50 users.
4. `GET /activity-count` still reports full totals (it reads the shared schedule set).

## Local testing

Run two schedulers against local Redis with explicit shard overrides:

```bash
SHARD_INDEX=0 SHARD_COUNT=2 ./LukaVapor serve --port 8080
SHARD_INDEX=1 SHARD_COUNT=2 ./LukaVapor serve --port 8081
```

Register sessions for a few usernames and confirm each appears in only one process's
`📥 Dequeued sessions` logs.
