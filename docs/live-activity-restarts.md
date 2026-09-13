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
| `session_start_rejected` | app | A registration for an activity that already ended (`reason`: `max_duration`, `client_end`, `apns_rejected`, `superseded`, …) was refused with 410. Expected occasionally: the app re-registers a just-dismissed activity on wake. |
| `session_start_failed` | app | The start route threw (undecodable body, Redis error) |

The `restart_registered` event is driven by a Redis marker
(`live-activities:restart-pending:<username>`, 8h TTL) written when a start push is sent
and consumed by the next registration. `session_started` and `restart_registered` carry
`launched_by_push` (the client's view of whether the system started the activity from a
push), which separates a late restart registration from a manual start.

### Client events (`client_event`)

The app posts what the device saw to `POST /client-event`, batched per wake and stamped
with the device clock. Each row has `client_event` (the name), `client_time`,
`client_lag_s` (upload delay), `app_version` / `app_build` / `os_version` /
`device_model`, `activity_prefix`, and — when a restart push is pending for the user —
`restart_source` and `since_restart_s`. The route sanitizes names and attributes
(`ClientEventSanitizer`); clients can't spoof server-stamped fields.

| `client_event` | Attributes | Meaning |
|---|---|---|
| `app_launch` | `app_state`, `activities`, `protected_data`, `restart_enabled`, `has_pts_token` | The process came up. After a `push_started`, this in `background` state is the proof iOS woke the app. |
| `activity_observed` | `source` (existing/updates), `push_to_start`, `state`, `reason` | The manager began observing an activity. `push_to_start=true` = the restarted activity exists on the device. |
| `token_received` | `kind`, `push_to_start`, `token_prefix` | ActivityKit handed over the activity's push token. |
| `token_sent` / `token_send_failed` / `token_send_skipped` | `kind`, `push_to_start`, `error` / `has_username` … | Registration outcome. `skipped` = credentials weren't readable. |
| `push_to_start_token` | `changed`, `had_token`, `pts_prefix` | The push-to-start token stream yielded. Compare `pts_prefix` with `token_prefix` on `push_started`. |
| `activity_ended` | `state`, `push_to_start`, `had_token` | iOS reported the activity ended or dismissed. |
| `end_sent` / `end_send_failed` | | The client's end call. |

TelemetryDeck (app `Luka`) carries the same observations as signals
(`LiveActivity.activityObserved`, `receivedToken`, `sentToken`, `failedToSendToken`,
`pushToStartTokenUpdated`, `activityEnded`) for fleet-level rates, but with server receipt
timestamps only — use `client_event` for timing.

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

**One user's restart history** (pair each `push_started` with what followed, server and
device side):
```apl
['luka-push']
| where user == "<redacted id>" and event in ("push_started", "restart_registered", "session_started", "session_ended", "push_ended", "client_event")
| extend when = iff(event == "client_event", todatetime(client_time), _time)
| project when, event, client_event, kind, reason, source, latency_s, since_restart_s, app_state, push_to_start, launched_by_push, token_prefix, pts_prefix, pts_prefix_sent, pts_prefix_now, pts_age_s, restarted_count, error
| order by when asc
```

**Did the device wake for each restart?** (`push_started` followed by a background
`app_launch` from the same user within 2 minutes):
```apl
let starts = ['luka-push'] | where event == "push_started" | project user, t0=_time;
let wakes = ['luka-push'] | where event == "client_event" and client_event == "app_launch" | project user, t1=todatetime(client_time), app_state;
starts
| join kind=leftouter wakes on user
| extend delta = datetime_diff('second', t1, t0)
| summarize woke = countif(delta >= 0 and delta <= 120) by user, t0
| summarize restarts=count(), device_woke=countif(woke > 0) by user
```

Monitor: **"Luka: push-to-start restarts not re-registered"** (Axiom, 60-minute window,
alerts above 6 dropped restarts) emails the same notifier as the 429 monitor.

## Two root causes found on 2026-09-13

**Stale push-to-start token (device-side).** A device's push-to-start token rotates, and
`pushToStartTokenUpdates` can stay silent for whole process lifetimes afterwards (seen on
iOS 26.6: five launches, zero yields). The app kept sending the token it had persisted
weeks earlier; APNs accepts a push to a well-formed old token without error, and the device
never sees it. Confirmed by a `liveactivitiesd` state dump in the device log
(`log collect --device`, then search `publicTokens`) that disagreed with the `token_prefix`
on `push_started`. The client now reads `Activity.pushToStartToken` directly on launch, on
foreground, and before every registration, and reports every read as a
`push_to_start_token` client event. In Axiom, compare `pts_prefix` on a user's
`push_to_start_token` events with `token_prefix` on their `push_started`.

**Stale re-registration race (server-side).** On a wake the app observes the just-dismissed activity next to the new one; the old
activity's token stream re-yields and the app registers it again a few milliseconds after
the new one. The start route used to treat whichever registration arrived last as the
newest and delete the other's token, so when the old one landed last the new activity on
screen had no token on the server and never updated, while pushes kept going to a dismissed
activity. Fleet-wide this starved ~4 activities a day. Two guards now close it: only a
brand-new activity ID may supersede (`supersededActivityIDs`), and every removed activity
is tombstoned (`live-activities:ended:<user>:<activityID>`) so a late registration for it
is refused with 410 (`session_start_rejected`). The client skips sends for dismissed
activities and treats 410 as "ended".

## Reading a failure

After a `push_started`, look at the same user's `client_event` rows ordered by
`client_time`:

- No `app_launch` until the user opens the app, then `activity_observed push_to_start=true
  source=existing` → iOS showed the restarted activity but never woke the app (the
  force-quit / not-woken case). The activity sat stale until the app ran.
- `app_launch app_state=background` but no `token_received` → the app woke and the
  push-token stream never yielded (Apple's known timing issue; read the token directly).
- `token_received` but `token_send_failed` / `token_send_skipped` → the app had the token
  and couldn't register (network, or credentials unreadable in the background).
- Nothing at all, ever, and the next activity is `launched_by_push=false` → the device
  never started the activity (token stale, Live Activities disabled, budget, Low Power).
  Compare `pts_prefix` on the user's `session_started` / `push_to_start_token` events with
  `token_prefix` on `push_started`.
- `restart_registered` with large `latency_s` and `launched_by_push=true` → the push was
  honored but the registration only happened when the app next ran.
