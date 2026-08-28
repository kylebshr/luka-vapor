# Claude Code Notes

## Sharded Polling

Dexcom polling is sharded across Fly worker machines (one static egress IP each) to stay
under Dexcom's per-IP rate limits. **Read `docs/scaling.md` before changing `fly.toml`
process groups, `SHARD_COUNT`, or machine counts** — mismatched values orphan a shard or
split one shard across two egress IPs.

## Job Queue Payload Changes

When modifying `LiveActivityJobPayload` or any other Queues job payload:

- **Never make optional fields required** - Existing jobs in the Redis queue will fail to decode and be cancelled
- Always add new fields as optional with a default/fallback
- Consider backwards compatibility since jobs may be queued for minutes before executing
