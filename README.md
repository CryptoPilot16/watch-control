# watch-control

> Approve [Codex](https://github.com/openai/codex) and [Claude Code](https://github.com/anthropics/claude-code) commands from your Apple Watch.

[![Live](https://img.shields.io/badge/live-cryptopilot.dev%2Fwatchcontrol-4ade80?style=flat-square)](https://cryptopilot.dev/watchcontrol)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

![watch-control landing page](assets/preview.png)

Your AI agent runs on a remote Linux server inside `tmux`. When it needs approval, the request reaches your Apple Watch instantly — either via a native watchOS app over Tailscale, or via Pushover push notification as a fallback. A single tap approves or denies, and your agent continues.

Supports Codex and Claude Code side-by-side, with two delivery paths:

- **Native Apple Watch app** — connects to a bridge server over Tailscale, shows the prompt on your wrist with Approve/Deny buttons
- **Pushover notifications** — optional fallback that works without the native app

---

## How it works

```
┌────────────────────┐
│  Codex / Claude    │  running in tmux on your Linux server
└─────────┬──────────┘
          │ needs approval
          ▼
┌────────────────────┐     ┌─────────────────┐
│  codex_watch.sh    │────▶│ approve_webhook │  injects keystroke into tmux
│  (tmux poller)     │     │     .py         │
└─────────┬──────────┘     └─────────────────┘
          │
          │ POST /hooks/codex
          ▼
┌────────────────────┐     ┌─────────────────┐
│  bridge/server.js  │────▶│  Apple Watch    │  Approve / Deny
│  (Node.js + SSE)   │     │   native app    │
└────────────────────┘     └─────────────────┘
          │
          │ (optional fallback)
          ▼
┌────────────────────┐
│     Pushover       │  notification with action button
└────────────────────┘
```

**Codex flow** — `codex_watch.sh` polls tmux every 2s, detects the approval prompt, POSTs to the bridge, blocks until your Watch responds, then injects the correct keystroke (`y`) into tmux.

**Claude Code flow** — Claude Code's native hook system POSTs directly to the bridge on `PermissionRequest`. The bridge blocks Claude until your Watch responds, then returns the decision so Claude resumes.

---

## Structure

```
watch-control/
├── approve_webhook.py        # HTTP webhook — validates secret, injects tmux keystrokes
├── codex_watch.sh            # Watcher — polls tmux, detects prompts, posts to bridge
├── restart.sh                # Start/restart both services
├── bridge/                   # Node.js bridge server for Apple Watch app
│   ├── server.js             # SSE bridge — handles pairing, hooks, watch responses
│   └── package.json
├── .env.example              # Environment variable template
└── web/                      # Landing page source (Next.js, static export)
```

---

## Quick start

**Prerequisites:** Linux server with tmux + Python 3 + Node.js 18+, [Tailscale](https://tailscale.com), and either an Apple Watch with the native app sideloaded, or a [Pushover](https://pushover.net) account.

```bash
git clone https://github.com/CryptoPilot16/watch-control.git watch-control
cd watch-control
cp .env.example .env
# edit .env — fill in APPROVE_SECRET (and PUSHOVER tokens if using fallback)
bash ./restart.sh
```

Start the bridge server (for the native Apple Watch app):

```bash
cd bridge && node server.js
```

The bridge prints a 6-digit pairing code at startup. Enter your Tailscale IP and that code into the Apple Watch app to pair.

---

## Apple Watch app

A native watchOS companion app connects to your bridge over Tailscale and shows approval requests on your wrist with one-tap Approve/Deny.

Repo: [github.com/CryptoPilot16/claude-watch](https://github.com/CryptoPilot16/claude-watch)

**Setup:**
1. Build and sideload the watchOS app via Xcode (requires Apple Developer account, $99/yr)
2. Install Tailscale on your Apple Watch / paired iPhone — same tailnet as your VPS
3. Open the app, enter your VPS Tailscale IP (e.g. `100.x.x.x`)
4. Enter the 6-digit pairing code shown by the bridge server
5. Done — approvals will appear on your wrist

---

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `APPROVE_SECRET` | yes | — | Shared secret for webhook auth |
| `BRIDGE_URL` | no | `http://100.x.x.x:7860` | Bridge server URL (Tailscale IP) |
| `PUSHOVER_APP_TOKEN` | no | — | Pushover app token (fallback notifications) |
| `PUSHOVER_USER_KEY` | no | — | Pushover user key (fallback notifications) |
| `TMUX_SESSION` | no | `codex:0.0` | Default tmux target pane |
| `TMUX_TARGETS` | no | `$TMUX_SESSION` | Space-separated list of panes to watch |
| `APPROVE_PORT` | no | `8787` | Webhook listening port |
| `COOLDOWN_SECONDS` | no | `30` | Min seconds between push notifications |

---

## Bridge endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pair` | POST | Pair the watch with a 6-digit code, returns session token |
| `/events` | GET | SSE stream — watch listens here for approval requests |
| `/command` | POST | Watch posts approval/deny decisions |
| `/hooks/permission` | POST | Claude Code `PermissionRequest` hook |
| `/hooks/tool-output` | POST | Claude Code `PostToolUse` hook |
| `/hooks/stop` | POST | Claude Code `Stop` hook |
| `/hooks/codex` | POST | Codex approval — `codex_watch.sh` posts here |
| `/status` | GET | Bridge health and session info |

---

## Webhook endpoints (legacy / Pushover path)

| Endpoint | Method | Description |
|---|---|---|
| `/approve` | GET/POST | Injects the queued approval keystroke into tmux |
| `/deny` | GET/POST | Sends Escape to the queued tmux pane |
| `/status` | GET/POST | Returns current queue depth |

Auth via `?secret=<APPROVE_SECRET>` query param or `X-Secret` header.

---

## Claude Code hooks setup

Add to `~/.claude/settings.json` so Claude Code POSTs to the bridge directly:

```json
{
  "hooks": {
    "PermissionRequest": [
      { "command": "curl -s -X POST http://100.x.x.x:7860/hooks/permission -H 'Content-Type: application/json' -d @-" }
    ],
    "PostToolUse": [
      { "command": "curl -s -X POST http://100.x.x.x:7860/hooks/tool-output -H 'Content-Type: application/json' -d @-" }
    ],
    "Stop": [
      { "command": "curl -s -X POST http://100.x.x.x:7860/hooks/stop -H 'Content-Type: application/json' -d @-" }
    ]
  }
}
```

Replace the Tailscale IP with your bridge server's address.

---

## Security

The webhook listens on `127.0.0.1` only and is exposed exclusively over your Tailscale tailnet. The bridge server binds to `0.0.0.0:7860` but is reachable only via your tailnet. Pairing requires a 6-digit code shown in the server logs, and all subsequent watch requests use a session token (Bearer auth). Rate-limiting prevents brute-force pairing attempts.

---

## Landing page

Live at [cryptopilot.dev/watchcontrol](https://cryptopilot.dev/watchcontrol)

```bash
cd web
npm install
npm run dev      # dev server
npm run build    # static export → out/
```

---

Built by [CryptoPilot16](https://github.com/CryptoPilot16) · [cryptopilot.dev](https://cryptopilot.dev)
