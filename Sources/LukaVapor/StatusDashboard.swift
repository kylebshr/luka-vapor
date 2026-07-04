import Foundation

/// Renders the activity-count response as a small self-contained HTML status page
/// for browsers. Programmatic clients still get JSON — see the route in routes.swift.
enum StatusDashboard {
    static func html(for counts: LiveActivityPollKeys.ActivityCounts) -> String {
        let tiles = [
            (label: "Sessions", value: counts.sessions, hint: "Dexcom accounts being polled"),
            (label: "Live Activities", value: counts.activities, hint: "Device tokens receiving pushes"),
            (label: "Rate limited", value: counts.rateLimited, hint: "Sessions backing off from Dexcom"),
        ]

        let tileMarkup = tiles.map { tile in
            """
                    <div class="tile">
                      <div class="label">\(tile.label)</div>
                      <div class="value">\(tile.value.formatted())</div>
                      <div class="hint">\(tile.hint)</div>
                    </div>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="30">
        <title>Luka status</title>
        <style>
          :root {
            color-scheme: light dark;
            --surface: #fafafa;
            --card: #ffffff;
            --border: #e4e4e7;
            --ink: #18181b;
            --ink-secondary: #52525b;
            --ink-muted: #a1a1aa;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --surface: #131316;
              --card: #1c1c20;
              --border: #2e2e33;
              --ink: #f4f4f5;
              --ink-secondary: #a1a1aa;
              --ink-muted: #6b6b74;
            }
          }
          * { box-sizing: border-box; margin: 0; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: var(--surface);
            color: var(--ink);
            display: grid;
            place-items: center;
            min-height: 100vh;
            padding: 24px;
          }
          main { width: 100%; max-width: 640px; }
          h1 { font-size: 1.25rem; font-weight: 600; }
          .subtitle { color: var(--ink-secondary); font-size: 0.875rem; margin-top: 4px; }
          .tiles {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 12px;
            margin-top: 20px;
          }
          .tile {
            background: var(--card);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 16px;
          }
          .label { font-size: 0.8125rem; color: var(--ink-secondary); }
          .value { font-size: 2.25rem; font-weight: 600; line-height: 1.2; margin-top: 6px; }
          .hint { font-size: 0.75rem; color: var(--ink-muted); margin-top: 4px; }
          .footer { color: var(--ink-muted); font-size: 0.75rem; margin-top: 16px; }
        </style>
        </head>
        <body>
          <main>
            <h1>Luka</h1>
            <p class="subtitle">Live Activity polling status · refreshes every 30 seconds</p>
            <div class="tiles">
        \(tileMarkup)
            </div>
            <p class="footer">Request with <code>Accept: application/json</code> for the raw counts.</p>
          </main>
        </body>
        </html>
        """
    }
}
