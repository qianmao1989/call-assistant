---
name: call-assistant
description: Call 小助理 via Gateway API. Auto-starts pipe server, auto-fallback to cc_outbox.md. Never fails silently.
version: 4.1.0
author: qianmao1989
license: MIT
tags: [messaging, multi-agent, gateway, pipe, reliability, openclaw]
---

# Call Assistant Skill

## When to use

ANY time CC needs to send a message to 小助理 (OpenClaw agent). This includes:
- Asking questions (data, files, schedules, etc.)
- Sending task results
- Any inter-agent communication

## Architecture

```
CC (Claude Code)                    Assistant (OpenClaw)
      │                                        │
      ├─ Gateway API (stream:true) ────────────→│  Primary: CC → Assistant
      │                                        │
      │                              Named Pipe ←│  Primary: Assistant → CC
      │                                        │
      └─ Outbox fallback ──────────────────────→│  Backup: both directions
```

## Pre-flight (automatic via script)

```
1. Read gateway token from openclaw.json (no hardcode, no env var)
2. Test pipe connectivity via CreateFile (not Get-Process CommandLine)
3. Auto-restart pipe server if dead (using python command, not hardcoded path)
4. Send via Invoke-WebRequest with stream:true
5. Parse streaming SSE response
6. Fallback: cc_outbox.md if Gateway fails
```

## Usage

```powershell
# One-shot call
$reply = .\call_assistant.ps1 "[CC] your message here"

# With longer timeout (default 120s)
$reply = .\call_assistant.ps1 "[CC] long task message" -Timeout 180
```

## Config sources (v4.1 — zero hardcode)

| Config | Source |
|--------|--------|
| Gateway URL | `http://localhost:18789` (fixed) |
| Token | Auto-read from `$env:USERPROFILE\.openclaw\openclaw.json` → `gateway.auth.token` |
| Model | `openclaw/main` (fixed) |
| Named Pipe | `\.\pipe\openclaw-cc-push` |
| Pipe Server | `shared/cc_push_server.py` |
| Fallback | `shared/cc_outbox.md` |

## Rules

1. **NEVER** hardcode token — script reads it from openclaw.json
2. **NEVER** use bash curl for Chinese content — use the PowerShell script
3. **ALWAYS** prefix message with `[CC]`
4. **USE ENGLISH** for AI-to-AI messages — avoids UTF-8→GBK encoding issues
5. **IF** script fails → check cc_outbox.md for reply after 30s
6. **NEVER** retry more than once — if script fails twice, escalate to user

## Requirements

- PowerShell 7+
- Python 3.8+ (with pywin32 for pipe server)
- OpenClaw gateway running on localhost:18789

## File Structure

```
call-assistant/
├── call_assistant.ps1              # Main script
├── SKILL.md                        # This file
├── _meta.json                      # Metadata
├── README.md                       # Project overview
├── install.ps1                     # One-click setup
├── .call-assistant.json.example    # Config template (optional)
├── shared/
│   ├── cc_push_server.py           # Pipe listener (Assistant → CC)
│   └── assistant_push.py           # Pipe client (manual push)
└── test/
    └── smoke_test.ps1              # End-to-end validation
```

## Reliability

| Scenario | Behavior |
|----------|----------|
| Gateway healthy | Direct streaming SSE call |
| Gateway timeout/401 | Retry once, then outbox |
| Pipe down | Auto-start + CreateFile verify |
| All channels down | Write cc_outbox.md, escalate |

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 4.1.0 | 2026-06-11 | Token from openclaw.json, pipe CreateFile test, python PATH lookup |
| 4.0.0 | 2026-06-10 | Smoke test, glob char class fix, ContentType, SSE parse robustness |

## License

MIT
