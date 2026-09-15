# Claude Code Notes

## Sharded Polling

Dexcom polling is sharded across Fly worker machines, one per region, each egressing from
that region's single app-scoped static egress IP, to stay under Dexcom's per-IP rate
limits. **Read `docs/scaling.md` before changing `fly.toml` process groups, `SHARD_COUNT`,
machine counts, or machine regions** — mismatched values orphan a shard, and two machines
in one region share (or randomly split) an egress IP.

If **Live Activities stop updating fleet-wide** — worker logs full of `NSURLErrorDomain
Code=-1001` poll timeouts and `Axiom ingest failed: connectTimeout`, worker telemetry dark
in Axiom — the workers' static egress IPs have wedged (a Fly host migration can silently
break outbound routing while the IP still shows allocated). Diagnose with
`./check-egress.sh`, fix with `./rotate-egress-ips.sh`. See "Wedged egress IPs" in
`docs/scaling.md`.

## Job Queue Payload Changes

When modifying `LiveActivityJobPayload` or any other Queues job payload:

- **Never make optional fields required** - Existing jobs in the Redis queue will fail to decode and be cancelled
- Always add new fields as optional with a default/fallback
- Consider backwards compatibility since jobs may be queued for minutes before executing

## Live Activity Restart Failures

If a user's activity goes stale right at the 7-hour mark, check `push_started` vs
`restart_registered` for that user in Axiom. Events, queries, and how to read them are in
`docs/live-activity-restarts.md`.
