# Claude Code Notes

## Job Queue Payload Changes

When modifying `LiveActivityJobPayload` or any other Queues job payload:

- **Never make optional fields required** - Existing jobs in the Redis queue will fail to decode and be cancelled
- Always add new fields as optional with a default/fallback
- Consider backwards compatibility since jobs may be queued for minutes before executing
