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
          │ POST /hooks/codex (or /hooks/permission for Claude Code)
          ▼
┌────────────────────┐     ┌─────────────────┐     ┌────────────────┐
│  bridge/server.js  │◀───▶│   iPhone app    │◀───▶│  Apple Watch   │
│  (Node.js + SSE)   │ SSE │  (relay + UI)   │ WC  │   native app   │
└────────────────────┘     └─────────────────┘     └────────────────┘
          │
          │ (optional fallback, no iPhone needed)
          ▼
┌────────────────────┐
│     Pushover       │  notification with action button
└────────────────────┘
```

The bridge talks to the **iPhone app** over SSE on your Tailscale tailnet. The iPhone app pairs with the bridge once (6-digit code), then keeps a long-lived event stream open and forwards approval requests to the **Apple Watch** over `WCSession`. Approve or deny on either device — the response flows back through the iPhone to the bridge, which unblocks the agent.

**Codex flow** — `codex_watch.sh` polls tmux every 2s, detects the approval prompt, POSTs to the bridge, blocks until your Watch (or iPhone) responds, then injects the correct keystroke (`y`) into tmux.

**Claude Code flow** — Claude Code's native hook system POSTs directly to the bridge on `PermissionRequest`. The bridge blocks Claude until your Watch (or iPhone) responds, then returns the decision so Claude resumes.

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
├── ios/                      # Native watchOS + iOS Xcode project
│   └── ClaudeWatch/          # SwiftUI app — pairs with bridge, shows approvals
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

## iPhone + Apple Watch app

A two-target SwiftUI app: an **iPhone app** that holds the bridge connection and a **watchOS app** that displays approvals on your wrist.

- The **iPhone app** does the actual Tailscale → bridge HTTP/SSE work and shows the prompt directly when the watch isn't paired or reachable.
- The **watchOS app** receives state and approval requests from the iPhone over `WCSession` (no internet on the watch required), and lets you tap Approve/Deny on your wrist.

Source lives in [`ios/`](ios/) — open `ios/ClaudeWatch/ClaudeWatch.xcodeproj` in Xcode.

**Setup:**
1. Open the Xcode project on a Mac. A paid Apple Developer account ($99/yr) is recommended — free accounts can sideload but watchOS sideloads are notoriously fragile.
2. Set your signing team in **ClaudeWatch iOS** and **ClaudeWatchWatch** targets (Signing & Capabilities → Team).
3. Install Tailscale on your iPhone — same tailnet as your VPS.
4. Plug your iPhone into the Mac, build and run the **`ClaudeWatch`** scheme targeting your iPhone. The watch app embeds and auto-installs on the paired Apple Watch.
5. On the iPhone, open the **watch-control** app. On the pairing screen, type your VPS's Tailscale IP into the **Bridge IP** field (e.g. `100.x.x.x`).
6. Enter the 6-digit pairing code shown by the bridge server's terminal.
7. Done — the iPhone shows approval prompts directly, and forwards them to the watch when you're wearing it.

> **Note on the Apple Watch app:** for sideloads on watchOS 10+ the Apple Watch needs **Developer Mode** turned on (Settings → Privacy & Security → Developer Mode → restart → confirm). Xcode will only "see" the watch as a build destination after both Developer Mode is enabled and the watch is registered via Window → Devices and Simulators.

> **Attribution:** the iOS/watchOS source was originally derived from [shobhit99/claude-watch](https://github.com/shobhit99/claude-watch). Adapted to use Tailscale instead of Bonjour, to integrate with this bridge server, and rebranded to watch-control.

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
