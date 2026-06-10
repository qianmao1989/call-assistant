# call-assistant v4.1

> **Reliable AI-to-AI messaging** — Gateway API + Named Pipe + Outbox fallback. Never fails silently.

Claude Code → OpenClaw assistant with automatic pipe server management and multi-layer fallback.

---

## Architecture

```
CC (Claude Code)                        Assistant (OpenClaw)
      │                                            │
      ├─── Gateway API (stream:true) ──────────────→  Primary: CC → Assistant
      │                                            │
      │                                Named Pipe ←──  Primary: Assistant → CC
      │                                            │
      └─── Outbox fallback ────────────────────────→  Backup: both directions
```

- **Gateway API** — CC sends messages, receives streaming responses
- **Named Pipe** — Assistant pushes replies back to CC (`\.\pipe\openclaw-cc-push`)
- **Outbox** — `shared/cc_outbox.md`, fallback when all channels are down

---

## What's New in v4.1

| Fix | Before | After |
|-----|--------|-------|
| Token source | Hardcoded or env var (session-loss risk) | Auto-read from `openclaw.json` |
| Pipe detection | `Get-Process CommandLine` (admin-dependent) | `CreateFile` direct pipe test |
| Python path | Hardcoded `Python310` path | `python` command (PATH lookup) |
| AI language | Chinese (encoding issues) | English (no mangled chars) |

---

## Quick Start

```powershell
# 1. Clone
git clone https://github.com/qianmao1989/call-assistant.git
cd call-assistant

# 2. Ensure requirements
pwsh --version    # 7+
python --version  # 3.8+
pip install pywin32

# 3. Gateway must be running (OpenClaw with gateway.auth.token configured)
curl http://localhost:18789/health

# 4. Call
.\call_assistant.ps1 "[CC] ping"
```

**Token is auto-read** from `$env:USERPROFILE\.openclaw\openclaw.json` → `gateway.auth.token`. No manual configuration needed.

---

## Usage

```powershell
# Basic call
.\call_assistant.ps1 "What's the weather?"

# Custom timeout (seconds, default 120)
.\call_assistant.ps1 "Run a long batch job" -Timeout 180
```

CC automatically prepends `[CC]` prefix. Replies come back as plain text.

---

## How It Works

```
Step 1 →  Read token from openclaw.json
Step 2 →  Test pipe via CreateFile, auto-restart if dead
Step 3 →  POST /v1/chat/completions with stream:true
          Parse SSE stream, reconstruct full reply
          Retry once on failure
Step 4 →  Output reply, or write to cc_outbox.md as fallback
```

---

## Protocol

| Direction | Prefix | Carrier |
|-----------|--------|---------|
| CC → Assistant | `[CC]` | Gateway API (POST) |
| Assistant → CC | `[Assistant]` | Named Pipe (JSON push) |

**Language rule:** AI-to-AI communication uses **English** to avoid encoding issues.

---

## Reliability

| Scenario | Behavior |
|----------|----------|
| Gateway healthy | Direct streaming SSE call |
| Gateway timeout/401 | Retry once, then outbox |
| Pipe dead | Auto-start + `CreateFile` verify |
| All down | Write `cc_outbox.md`, escalate |

---

## Requirements

- **PowerShell 7+**
- **Python 3.8+** (with pywin32)
- **OpenClaw** gateway running on `localhost:18789`

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Cannot read gateway token` | Check `~/.openclaw/openclaw.json` has `gateway.auth.token` |
| `Gateway not reachable` | Is OpenClaw running? `curl localhost:18789/health` |
| `Pipe unreachable` | Run `python shared/cc_push_server.py` manually |
| Empty response | Check model name is `openclaw/main` |

---

## License

MIT — [qianmao1989](https://github.com/qianmao1989)
