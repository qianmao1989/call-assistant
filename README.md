# call-assistant v4.0

> **Reliable AI-to-AI messaging** — Gateway API + Named Pipe + Outbox fallback. Never fails silently.

Claude Code → OpenClaw/Hermes (or any OpenAI-compatible gateway) with automatic pipe server management and multi-layer fallback.

---

## Architecture

```
CC (Claude Code)                        Assistant (OpenClaw/Hermes)
      │                                            │
      ├─── Gateway API (stream:true) ──────────────→  Primary: CC → Assistant
      │                                            │
      │                                Named Pipe ←──  Primary: Assistant → CC
      │                                            │
      └─── Outbox fallback ────────────────────────→  Backup: both directions
```

- **Gateway API** — CC sends messages, receives streaming responses
- **Named Pipe** — Assistant pushes replies back to CC (`\\.\pipe\openclaw-cc-push`)
- **Outbox** — `shared/cc_outbox.md`, fallback when all channels are down

---

## Quick Start

```powershell
# 1. Clone
git clone https://github.com/qianmao1989/call-assistant.git
cd call-assistant

# 2. Install (checks PS version, Python, creates config)
.\install.ps1

# 3. Configure
notepad .call-assistant.json
# Set gateway URL, token env var name, model

# 4. Set token
[Environment]::SetEnvironmentVariable('GATEWAY_TOKEN', 'your-token', 'Machine')
# Restart terminal

# 5. Test
.\test\smoke_test.ps1
```

---

## Usage

```powershell
# Basic call
.\call_assistant.ps1 "What's the weather?"

# Custom timeout (seconds)
.\call_assistant.ps1 "Run a long batch job" -Timeout 180

# Custom config path
.\call_assistant.ps1 "message" -Config "./prod/.call-assistant.json"
```

CC automatically prepends `[CC]` prefix to all messages. Replies come back without prefix — just the raw assistant response text.

---

## Configuration (`.call-assistant.json`)

```json
{
  "gateway": {
    "url": "http://localhost:18789",
    "token_env": "GATEWAY_TOKEN",
    "model": "openclaw/main",
    "health_endpoint": "/health",
    "chat_endpoint": "/v1/chat/completions"
  },
  "pipe": {
    "server_script": "./shared/cc_push_server.py",
    "pipe_name": "openclaw-cc-push",
    "python": "python",
    "startup_wait_sec": 3
  },
  "fallback": {
    "outbox": "./shared/cc_outbox.md",
    "timeout_sec": 120,
    "max_retries": 1,
    "retry_delay_sec": 2
  }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `gateway.url` | `http://localhost:18789` | Assistant gateway base URL |
| `gateway.token_env` | `GATEWAY_TOKEN` | Env var holding Bearer token |
| `gateway.model` | `openclaw/main` | Model name sent to chat completions |
| `pipe.server_script` | `./shared/cc_push_server.py` | Path to pipe listener |
| `pipe.pipe_name` | `openclaw-cc-push` | Windows named pipe name |
| `fallback.outbox` | `./shared/cc_outbox.md` | Fallback message dump |
| `fallback.timeout_sec` | `120` | Gateway request timeout |
| `fallback.max_retries` | `1` | Retries before outbox fallback |

---

## How It Works (5-Step Flow)

```
Step 0   →  Load config (.call-assistant.json), merge with defaults
Step 0.5 →  Validate $env:GATEWAY_TOKEN is set
Step 1   →  Gateway health check (GET /health)
Step 2   →  Auto-start cc_push_server.py if not running
Step 3   →  POST to /v1/chat/completions with stream:true
            Parse SSE stream, reconstruct full reply
            Retry on failure (configurable count + delay)
Step 4   →  Output reply to stdout, OR write to outbox on total failure
```

---

## Protocol

Messages use a simple prefix convention:

| Direction | Prefix | Carrier |
|-----------|--------|---------|
| CC → Assistant | `[CC]` | Gateway API (POST) |
| Assistant → CC | `[Assistant]` | Named Pipe (JSON push) |

**Language rule:** AI-to-AI communication uses **English** to avoid encoding issues. Human-facing communication is unaffected.

---

## Reliability

| Scenario | Behavior |
|----------|----------|
| Gateway healthy | Direct streaming call, parse SSE |
| Gateway timeout | Retry (configurable count + delay), then outbox |
| Empty response on retry 1 | Retry 2 with delay |
| Pipe server not running | Auto-start before each call, verify startup |
| All channels down | Write to `cc_outbox.md`, output FALLBACK message to user |
| Config missing | Merge with built-in defaults, warn |

---

## Requirements

- **PowerShell 7+** (tested on 7.6.2)
- **Python 3.8+** (for pipe server)
- **Running assistant gateway** (OpenClaw, Hermes, or any OpenAI-compatible endpoint)
- **Windows** (named pipe is Windows-specific)

---

## File Structure

```
call-assistant/
├── call_assistant.ps1              # Main script — CC calls this
├── install.ps1                     # One-click setup
├── SKILL.md                        # Skill documentation
├── README.md                       # This file
├── .call-assistant.json.example    # Config template
├── .call-assistant.json            # Your config (git-ignored)
├── .gitignore
├── shared/
│   ├── cc_push_server.py           # Pipe listener (Assistant → CC)
│   └── assistant_push.py           # Pipe client (for manual push)
└── test/
    └── smoke_test.ps1              # End-to-end validation
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `MISSING TOKEN` | `$env:GATEWAY_TOKEN` not set — see install output |
| `Gateway not reachable` | Is OpenClaw/Hermes running? `curl http://localhost:18789/health` |
| `Pipe server may not have started` | Run `python shared/cc_push_server.py` manually |
| `Attempt returned empty` | Gateway responded but no content — check model name |
| `FALLBACK: Message written to outbox` | Gateway down after retries — check `shared/cc_outbox.md` |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 4.0.0 | 2026-06-10 | Smoke test, fixes: glob char class, ContentType, Get-CimInstance, pipe verify, SSE parse |
| 3.0.0 | 2026-06-10 | Full English rewrite, named pipe primary, Gateway API streaming |
| 2.0.0 | 2026-06-04 | Named pipe upgrade from shared inbox |
| 1.0.0 | 2026-05-31 | Initial shared inbox prototype |

---

## License

MIT — [qianmao1989](https://github.com/qianmao1989)
