# Live Activity restarts: telemetry and diagnosis

A Live Activity hits its 7-hour max duration on the shard worker, which dismisses it
and sends a **push-to-start** push to the device's push-to-start token. The device is
expected to launch a new activity, capture its push token, and re-register via
`start-live-activity` within seconds. When that hand-off fails the user sees a stale or
missing activity until they start one by hand, and the server has nothing to poll.

## Events (Axiom dataset `luka-push`)

| Event | Emitted by | Meaning |
|---|---|---|
| `push_ended` reason `max_duration_restarted` | worker | Old activity dismissed at the 7h limit |
| `push_started` kind `push_to_start` | worker (or debug route, `source` in marker) | APNs **accepted** the start push. `pts_age_s` = seconds since the client last changed this push-to-start token. |
| `session_ended` reason `all_tokens_expired` | worker | Session torn down after expiry; `restarted_count` says how many restart pushes went out |
| `restart_registered` | app | The device came back: first `start-live-activity` after a restart push. `latency_s`, `source` (`max_duration`/`debug`), `pts_prefix_sent` vs `pts_prefix_now` |
| `session_started` | app | Every registration. `pts_prefix` = current push-to-start token prefix (`none` if opted out), `pts_changed` = differs from this activity's last registration (`none` = first registration) |
| `session_ended` reason `client_end` / `client_end_all` | app | Client-initiated teardown (`session_removed` says whether the whole session went) |
| `session_removed` reason `missing` / `undecodable` | worker | Dead schedule entry cleaned up |

The `restart_registered` event is driven by a 15-minute Redis marker
(`live-activities:restart-pending:<username>`) written when a start push is sent and
consumed by the next registration.

Client side (TelemetryDeck, app `Luka`): `LiveActivity.activityObserved`
(`pushToStart: true` = the device did launch the restarted activity),
`LiveActivity.receivedToken` / `sentToken` / `failedToSendToken` (all carry `pushToStart`),
`LiveActivity.pushToStartTokenUpdated` (`changed`), `LiveActivity.activityEnded`.

## Queries

**Restart success rate per day** (a `push_started` with no `restart_registered` within
5 min is a dropped restart; baseline ≈ 5% fleet-wide):
```apl
['luka-push']
| where event in ("push_started", "restart_registered")
| summarize sent = countif(event == "push_started"), back = countif(event == "restart_registered") by bin(_time, 1d)
| extend dropped_pct = round(100.0 * (sent - back) / sent, 1)
```

**Which users drop restarts** (persistent offenders are device-side):
```apl
['luka-push']
| where event in ("push_started", "restart_registered")
| summarize sent = countif(event == "push_started"), back = countif(event == "restart_registered") by user
| where sent > back
| extend dropped_pct = round(100.0 * (sent - back) / sent, 0)
| order by sent - back desc
```

**One user's restart history** (pair each `push_started` with what followed):
```apl
['luka-push']
| where user == "<redacted id>" and event in ("push_started", "restart_registered", "session_started", "session_ended", "push_ended")
| project _time, event, kind, reason, source, latency_s, token_prefix, pts_prefix, pts_prefix_sent, pts_prefix_now, pts_age_s, restarted_count
| order by _time asc
```

Monitor: **"Luka: push-to-start restarts not re-registered"** (Axiom, 60-minute window,
alerts above 6 dropped restarts) emails the same notifier as the 429 monitor.

## Reading a failure

- `push_started` present, `restart_registered` absent, and TelemetryDeck shows no
  `activityObserved pushToStart=true` → iOS did not launch the activity from the push
  (token stale, Live Activities disabled, or system throttling). Compare `pts_prefix` on
  the user's `session_started` events with `token_prefix` on `push_started`: if the client
  keeps advertising the same token the server pushes to, the token itself is suspect.
- `activityObserved pushToStart=true` but no `restart_registered` → the app was launched
  but the registration never reached the server (`failedToSendToken`).
- `restart_registered` with large `latency_s` → the push was delivered late (APNs stored
  it; check the device was offline).
