# Scaling the polling fleet

> For the step-by-step operational checklist (with the diagnostic Axiom queries), use the
> `scale-polling-fleet` skill in `.claude/skills/`. This doc is the reference behind it.

## How polling is distributed

All Dexcom polling is sharded across dedicated worker machines, each egressing from its
own **static egress IP**, so Dexcom sees a handful of low-volume IPs instead of one busy
one (their rate limiting is per-IP; see the plan/discussion in the PR that introduced this).

- The `app` process group serves HTTP only — it never polls and never touches Dexcom.
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

## One worker per region: how each worker gets its own IP

Egress IPs are **app-scoped** (`fly ips allocate-egress`), which is the only kind Fly
still supports — machine-scoped IPs (`fly machine egress-ip allocate`) are retired as of
Oct 31, 2026. App-scoped IPs are **regional**: every machine of the app in a region
egresses through one of that region's pool IPs, picked **at random**, with no way to pin
a machine to a particular IP. Two workers in the same region with two pool IPs would
therefore drift between IPs (observed: they all collapse onto one), defeating the
one-stable-IP-per-shard model.

The topology that makes the random pick deterministic: **exactly one worker machine per
region, and exactly one egress IP pair per region.** A pool of one has nothing to
randomize.

| Group   | Region | Notes                                                        |
|---------|--------|--------------------------------------------------------------|
| app     | sjc    | HTTP only. Shares sjc's pool IP with worker0 — harmless, it never calls Dexcom. |
| worker0 | sjc    | `primary_region`                                             |
| worker1 | lax    |                                                              |
| worker2 | dfw    |                                                              |
| worker3 | ord    |                                                              |
| worker4 | iad    |                                                              |
| worker5 | ewr    |                                                              |

Polling is latency-insensitive, so any US region works for Dexcom. The remaining unused
North American region is `yyz` (Toronto); beyond that, the next scale-up step is splitting
workers into separate Fly apps (one app = one IP pool), which is Fly's own recommended
pattern for per-machine IP isolation.

Because app-scoped IPs belong to the app rather than a machine, they **survive machine
recreation, host migration, and redeploys** — the "IP silently released" failure mode of
the machine-scoped era is gone.

Sanity check at any time — one IP pair per region, and every region with a worker:

```bash
fly ips list -a luka-vapor-v2 | grep egress
fly machines list -a luka-vapor-v2
```

## Scale up (add a worker)

Example: going from 6 workers to 7, into region `yyz`.

1. In `fly.toml`, add the new process group and bump the count — both in one change:

   ```toml
   [processes]
     worker6 = 'serve --env production --hostname 0.0.0.0 --port 8080'

   [env]
     SHARD_COUNT = '7'
   ```

2. Allocate the new region's egress IP **before** the machine exists there (Fly notes a
   newly allocated IP can take 5–10 minutes to apply to already-running machines; a
   machine created after allocation uses it from its first boot):

   ```bash
   fly ips allocate-egress -r yyz -a luka-vapor-v2 -y
   ```

3. Deploy. Merging the fly.toml change to `main` deploys it (Fly GitHub integration) and
   creates the new worker machine — in `primary_region` (sjc), where it would share
   worker0's IP. To deploy out of band instead:

   ```bash
   fly deploy --ha=false -a luka-vapor-v2
   ```

   Pass `--ha=false` so Fly creates **one** machine per new group. Without it, each group
   also gets a **stopped standby** machine; destroy any standby (`fly machine destroy
   <id>`) — if one ever started it would share its region's IP with the real worker.

4. Move the new worker out of sjc into its region, then remove the sjc one:

   ```bash
   fly machines list -a luka-vapor-v2                        # sjc machine ID for worker6
   fly machine clone <sjc-machine-id> -r yyz -a luka-vapor-v2
   fly machine destroy <sjc-machine-id> --force -a luka-vapor-v2
   ```

   Cloning copies the process-group metadata, so the clone boots as shard 6. Both
   machines briefly own the shard; the atomic claim keeps that harmless.

5. Verify (see "Verifying a change"). Quick check from the box itself:

   ```bash
   ./check-egress.sh          # every started worker: region, egress source IP, reachability
   ```

## Scale down (remove a worker)

Example: going from 7 workers back to 6. Remove the **highest-indexed** group so the
remaining indices stay contiguous (`worker0..worker5` for `SHARD_COUNT = 6`) — a worker
whose index ≥ `SHARD_COUNT` refuses to poll.

1. In `fly.toml`, delete the `worker6` line and set `SHARD_COUNT = '6'`.
2. Deploy, then destroy the group's machine and release the now-unused region's IPs
   (they are billed while allocated):

   ```bash
   fly deploy
   fly scale count worker6=0 -a luka-vapor-v2 -y
   fly ips list -a luka-vapor-v2 | grep yyz
   fly ips release-egress <v4> <v6> -a luka-vapor-v2
   ```

Sessions previously owned by the removed shard are re-owned by the remaining workers on
their next due tick (rehash) — no manual migration, worst case a few minutes of delayed
polls during the deploy.

## Deploys triggered from GitHub merges

Merge-triggered `fly deploy` handles almost everything: process groups and `SHARD_COUNT`
come from the repo's `fly.toml`, and existing machines are updated **in place**, which
preserves their region and therefore their egress IP. Ordinary merges need no manual
follow-up.

The exception is a **new worker group**: the deploy creates its machine in
`primary_region` (sjc), so it needs the clone-to-region step from "Scale up" above. Until
then it polls from sjc's IP alongside worker0, roughly doubling that IP's load — not an
outage, but don't leave it long.

When a merge *removes* a worker group, verify the machine is actually gone
(`fly machines list`) and scale it to zero if it lingers.

## Wedged egress IPs (outbound timeouts)

**This took the whole polling fleet down** in the machine-scoped era: a Fly host migration
would rebuild a worker's network namespace and silently break its egress binding. The IP
still showed as allocated, but **all outbound traffic through it timed out**. App-scoped
IPs are designed around machines being rescheduled, so this may no longer happen — but
keep the diagnosis and fix path until that's proven over time.

Symptoms (across one or more workers, surviving a redeploy):

- Every poll fails: `🚫 Error polling for session: Error Domain=NSURLErrorDomain
  Code=-1001` (`-1001` = request timed out). Sessions eventually force-end with
  `tooManyRetries`, so Live Activities stop updating.
- `Axiom ingest failed: HTTPClientError.connectTimeout` in the Fly logs — the workers
  can't reach Axiom either.
- **In Axiom the worker telemetry goes dark**: `scheduler_tick`, `poll`, and `push_sent`
  flatline while `session_started` keeps coming. That is misleading — those worker events
  vanish because the workers can't *reach* Axiom, not because the scheduler stopped. Trust
  the Fly logs (`fly logs --machine <id>`) over Axiom silence here.
- If it's IP-level, the `app` machine is affected too now (it shares sjc's IP with
  worker0) — so an app-healthy / workers-dead split points at something else.

Confirm it by probing outbound reachability from each worker:

```bash
./check-egress.sh          # prints reach dexcom / reach axiom OK|FAIL + source IP per worker
```

Fix: rotate the affected worker's **region** IP — release it, allocate a fresh pair in the
same region, restart the machine. You get a fresh IP, which is fine (even good) for
Dexcom's per-IP limits. The helper does all three and re-probes:

```bash
./rotate-egress-ips.sh          # all workers (prompts first); -y to skip, -n to dry-run
./rotate-egress-ips.sh <id>     # just one worker
```

**A rotate must be followed by a machine restart.** Reallocating the IP restores raw
reachability, but the running process keeps two connection pools — `URLSession.shared`
(CGM polling) and async-http-client (Axiom) — full of keep-alive connections pinned to the
*old* egress IP. The app keeps reusing those now-dead connections, and every reuse hangs
to its timeout: `NSURLErrorDomain -1001` on polls, `HTTPClientError.connectTimeout` on
Axiom ingest. So a rotate *without* a restart looks like it "didn't work" — polls keep
timing out (~35–60% of them, worst on the least-frequently-polled sessions) even though
`openssl s_client` from the box connects instantly on a fresh connection. `fly machine
restart <id>` flushes both pools and clears it immediately. `rotate-egress-ips.sh` does
this automatically after each reallocation; if you rotate by hand, restart the machine.
Rotating sjc also restarts the `app` machine, since it shares that IP.

If reallocation + restart doesn't fix it, the next steps are destroying + recreating the
wedged machine in the same region (`fly machine clone`, then destroy the old one), and
failing that, treating it as a Fly platform incident. **Set the alert:** a shard with no
`scheduler_tick` for >2 minutes (see "Verifying a change") is the earliest signal of this.

## Rules that keep this safe

- **Exactly one machine per worker group, and exactly one worker per region.** A second
  machine in a region — a standby, a lingering pre-clone machine, or two groups placed in
  the same region — shares that region's IP, doubling its load; two IP pairs in one
  region get picked at random, splitting a shard's users across IPs. The atomic claim
  prevents double-polling either way, but the stable-IP goal is lost.
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
fly scale count worker0=0 worker1=0 worker2=0 worker3=0 worker4=0 worker5=0 -a luka-vapor-v2 -y
```

With `SHARD_COUNT` unset the process falls back to legacy mode — shard (0, 1) — and the
single `app` machine polls everything from its own IP again (sjc's pool IP), exactly the
pre-sharding behavior. This is also how local dev runs.

## Verifying a change

1. **Logs**: each worker logs `Scheduler enabled for shard i/N` on boot; the app machine
   logs `Scheduler disabled (HTTP-only process)`.
2. **Axiom** (all events carry `machine_id`, `process_group`, `shard` automatically):
   - one `boot` event per machine with a distinct `egress_ip` per worker (the `app`
     machine's matches worker0's — expected);
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
