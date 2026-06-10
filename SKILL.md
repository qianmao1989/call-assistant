---
name: call-assistant
description: Reliable AI-to-AI messaging via Gateway API + Named Pipe. Auto-starts pipe server, auto-fallback to outbox. Never fails silently.
version: 4.0.0
author: qianmao1989
license: MIT
tags: [messaging, multi-agent, gateway, pipe, reliability]
---

# Call Assistant Skill

Reliable communication channel between Claude Code and a local AI assistant (OpenClaw / Hermes / any OpenAI-compatible gateway).

## Architecture

```
CC (Claude Code)                    Assistant (OpenClaw/Hermes)
      │                                        │
      ├─ Gateway API (stream:true) ────────────→│  Primary: CC → Assistant
      │                                        │
      │                              Named Pipe ←│  Primary: Assistant → CC
      │                                        │
      └─ Outbox fallback ──────────────────────→│  Backup: both directions
```

**Two primary channels, one backup.** If Gateway fails, message is written to shared outbox. Never loses a message.

## Quick Start

```powershell
# 1. Clone
git clone https://github.com/qianmao1989/call-assistant.git

# 2. Install
.\install.ps1

# 3. Configure
notepad .call-assistant.json

# 4. Test
.\test\smoke_test.ps1
```

## Usage

```powershell
# Call assistant
.\call_assistant.ps1 "What's the weather?"

# Custom timeout
.\call_assistant.ps1 "Run batch job" -Timeout 180

# Custom config path
.\call_assistant.ps1 "msg" -Config "./prod/.call-assistant.json"
```

## Configuration

Copy `.call-assistant.json.example` to `.call-assistant.json`:

```json
{
  "gateway": {
    "url": "http://localhost:18789",
    "token_env": "GATEWAY_TOKEN",
    "model": "openclaw/main"
  },
  "pipe": {
    "server_script": "./shared/cc_push_server.py",
    "python": "python"
  },
  "fallback": {
    "outbox": "./shared/cc_outbox.md",
    "timeout_sec": 120,
    "max_retries": 1
  }
}
```

Set your gateway token as an environment variable:

```powershell
[Environment]::SetEnvironmentVariable('GATEWAY_TOKEN', 'your-token', 'Machine')
```

## Requirements

- PowerShell 7+
- Python 3.8+
- A running OpenAI-compatible gateway (OpenClaw, Hermes, etc.)

## How It Works

1. **Pre-flight** — validates `$env:GATEWAY_TOKEN` is set, Gateway `/health` responds
2. **Pipe server** — auto-starts `cc_push_server.py` if not running
3. **Send** — POSTs to Gateway v1/chat/completions with `stream:true`
4. **Parse** — extracts streaming SSE response
5. **Fallback** — on failure, writes to `cc_outbox.md`, tells user to check back

## Protocol

Messages use a simple prefix convention:
- CC → Assistant: `[CC]` prefix
- Assistant → CC: `[Assistant]` prefix

## Reliability

| Scenario | Behavior |
|----------|----------|
| Gateway healthy | Direct streaming call |
| Gateway timeout | Retry once, then outbox |
| Pipe server down | Auto-start before each call |
| All channels down | Write outbox, escalate to user |

## License

MIT
