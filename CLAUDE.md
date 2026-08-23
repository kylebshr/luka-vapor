# Claude Code Notes

## Sharded Polling

Dexcom polling is sharded across Fly worker machines (one static egress IP each) to stay
under Dexcom's per-IP rate limits. **Read `docs/scaling.md` before changing `fly.toml`
process groups, `SHARD_COUNT`, or machine counts** — mismatched values orphan a shard or
split one shard across two egress IPs.

If **Live Activities stop updating fleet-wide** — worker logs full of `NSURLErrorDomain
Code=-1001` poll timeouts and `Axiom ingest failed: connectTimeout`, worker telemetry dark
in Axiom while the `app` machine is healthy — the workers' static egress IPs have wedged
(a Fly host migration can silently break outbound routing while the IP still shows
allocated). Fix: `./rotate-egress-ips.sh`. See "Wedged egress IPs" in `docs/scaling.md`.

## Job Queue Payload Changes

When modifying `LiveActivityJobPayload` or any other Queues job payload:

- **Never make optional fields required** - Existing jobs in the Redis queue will fail to decode and be cancelled
- Always add new fields as optional with a default/fallback
- Consider backwards compatibility since jobs may be queued for minutes before executing

## CGM Providers

Live Activity sessions poll either Dexcom Share or LibreLinkUp (`CGMProvider`, stored in
the session's `cred` field). A missing provider always means Dexcom — pre-Libre clients
and Redis entries don't have one. Libre sessions share the same schedule key, Redis
namespace, and shard routing as Dexcom, but poll on a flat one-minute cadence (readings
arrive every minute) instead of the boundary/catch-up logic tuned for Dexcom's 5-minute
readings, and treat both 429 and the nonstandard 430 as rate limits.
