---
name: call-assistant
description: Call 小助理 via Gateway doorbell. Outbox=message body (primary), Gateway=doorbell (notification only). Auto-starts pipe server. English-only for AI-to-AI. Never fails silently.
version: 5.0.0
author: qianmao1989
license: MIT
tags: [messaging, multi-agent, gateway, pipe, doorbell-pattern, reliability, openclaw]
---

# Call Assistant Skill

## When to use

ANY time CC needs to send a message to 小助理 (OpenClaw agent). This includes:
- Asking questions (data, files, schedules, etc.)
- Sending task results
- C5 sync notifications (after modifying shared config files)
- Any inter-agent communication

## Core Pattern: Doorbell (门铃模式)

**This is the locked-in, single-path communication protocol. No alternatives. No "trying something else."**

```
Outbox = Message Body (complete content)
Gateway = Doorbell (one-line notification only — never carry body content)
```

Why locked: DeepSeek v4-pro instruction-following is weaker than Claude's. Presenting "multiple channels" makes it pick one at random. Only one path exists — no choice to make.

## Architecture

```
CC (Claude Code) ──outbox (full message)──→ shared/cc_outbox.md ←── 小助理 reads
CC (Claude Code) ──Gateway doorbell──────→ "去看 cc_outbox.md"
CC (Claude Code) ←──Named Pipe─────────── 小助理's reply pushed in
```

| Channel | Direction | Role | Content |
|---------|-----------|------|---------|
| `shared/cc_outbox.md` | CC → 小助理 | **Primary** message body | Full message content |
| Gateway API (stream:true) | CC → 小助理 | **Doorbell** notification | One line only: "去看 cc_outbox.md" |
| Named Pipe `openclaw-cc-push` | 小助理 → CC | **Primary** receive | 小助理's reply pushed via `cc_push_server.py` |
| `shared/cc_outbox.md` | 小助理 → CC | **Fallback** receive | If pipe is dead, 小助理 writes reply here |

## Language Rules

- **AI-to-AI messages: English ONLY.** This is mandatory.
- Doorbell in English, outbox body in English, pipe messages in English.
- Why: Prevents UTF-8→GBK encoding corruption across Windows pipe/Gateway boundaries.

## Message Type Format (Outbox Header)

**Every outbox message MUST include a `Type:` header.** This tells 小助理 whether to reply or not.

```
Type: question | task_request | task_result | sync-notification | alert
```

| Type | Purpose | Reply Required |
|------|---------|---------------|
| `question` | Ask 小助理 for info/opinion | ✅ Yes |
| `task_request` | Delegate a task to 小助理 | ✅ Yes (process + reply) |
| `task_result` | CC reports task completion to 小助理 | ✅ Yes (acknowledge) |
| `sync-notification` | C5 config sync notification | ❌ No reply needed |
| `alert` | Urgent alert (proxy down, etc.) | ✅ Yes |

### Format Template

```
# CC → 小助理 | YYYY-MM-DD

Type: <type>

## <title>

<body>
```

### Example: C5 Sync Notification

```
# CC → 小助理 | 2026-06-15

Type: sync-notification (no reply needed)

## C5 Sync: CLAUDE.md updated
...
```

## Usage

### Via script (automated pipe + outbox + doorbell)

```powershell
# One-shot call
.\call_assistant.ps1 "your message in English"

# Pipe-only init (run once per session)
.\call_assistant.ps1 -Init

# With explicit token
.\call_assistant.ps1 "msg" -Token "sk-..."
```

### Via manual steps (when script unavailable)

```
Step 1: Write D:\CherryAI_Workspace\shared\cc_outbox.md (complete message, English)
Step 2: Gateway API POST http://localhost:18789/v1/chat/completions
        Body: "去看 cc_outbox.md"
        Headers: Authorization: Bearer <token>
        stream: true (MANDATORY)
```

## Pre-flight Checklist

Before sending, verify in this order:

1. ✅ Pipe server alive → `Get-Process python* | Where CommandLine -like '*cc_push*'`
2. ✅ If dead → restart: `python D:\CherryAI_Workspace\shared\cc_push_server.py`
3. ✅ Write outbox → full message content in `shared/cc_outbox.md`
4. ✅ Gateway doorbell → one line only, stream:true mandatory

## Send Flow (Step by Step)

```
1. WRITE outbox           shared/cc_outbox.md ← complete message (English)
2. CHECK pipe server      Must be running before Gateway call
3. CALL Gateway           POST /v1/chat/completions
                          Body: "去看 cc_outbox.md" (NOTHING ELSE)
                          stream: true (MANDATORY, non-negotiable)
4. PARSE SSE response     Read streaming reply (acknowledgment from 小助理)
5. REPORT reply           Relay 小助理's response to 乾茂 (summarize, don't paste raw)
```

## Receive Flow (How CC Gets Replies from 小助理)

```
1. PIPE PUSH              小助理 writes reply → pushes through \\.\pipe\openclaw-cc-push
2. cc_push_server.py       Listens on pipe, receives reply, outputs to stdout
3. CC READS                CC reads reply in real-time via the pipe listener
4. CC ACTS                 Process reply: relay summary to 乾茂, take action, etc.

Fallback: If pipe is dead and 小助理 can't push, 小助理 writes reply to cc_outbox.md
→ CC checks outbox after Gateway timeout + 30s
```

## Golden Rules (Prohibitions)

| # | Rule | Why |
|---|------|-----|
| ❌ | **NEVER** put message body in Gateway | Timeout, deadlock, verified by 乾茂 |
| ❌ | **NEVER** write directly to named pipe (CC→助理 direction) | Pipe is 小助理→CC only |
| ❌ | **NEVER** use `call_assistant.ps1` for long messages (>3 steps) | Script puts body in outbox, doorbell is fine — but long replies from 小助理 may timeout. Split long tasks. |
| ❌ | **NEVER** switch to Feishu/QQ/Email/other channels | No other channels exist |
| ❌ | **NEVER** say "let me try another way this time" | No other way. Doorbell is the only way, verified fastest. |
| ❌ | **NEVER** use Chinese for AI-to-AI messages | UTF-8→GBK encoding corruption risk |
| ❌ | **NEVER** skip stream:true | Non-streaming Gateway calls timeout |
| ❌ | **NEVER** skip pipe server check before sending | If pipe is dead, 小助理's reply can't reach CC |

## Fault Classification

When something fails, classify BEFORE deciding how to handle:

| Type | Examples | Action |
|------|----------|--------|
| **Internal** (CC can fix) | Pipe server dead, Python not found | Auto-restart pipe, retry once |
| **External** (CC cannot fix) | Gateway 401/403/503, API down, network broken | Do NOT retry. Escalate to 小助理 immediately. |
| **Timeout** | Gateway >60s no response | Message already in outbox (safe). Report to 乾茂, suggest checking outbox manually. |

## Timeout Rules

| Scenario | Timeout | Reason |
|----------|---------|--------|
| Gateway doorbell call | **60s** | Doorbell is one short line — should respond in seconds |
| Pipe server startup wait | 3s | Enough for Python to bind the pipe |
| Max retries (internal errors) | 1 retry | Per C3 rule — fail twice → escalate |

## C5 Sync Notification

After modifying any shared config file (CLAUDE.md, call-assistant scripts, SKILL.md, etc.):

1. `git add` + `git commit` the changes
2. `git push` to remote
3. Send doorbell to 小助理: "去看 cc_outbox.md" with sync summary in outbox
4. 小助理 acknowledges receipt

## Config Sources

| Config | Source |
|--------|--------|
| Gateway URL | `http://localhost:18789` (fixed) |
| Gateway Token | Auto-read from `$env:USERPROFILE\.openclaw\openclaw.json` → `gateway.auth.token` |
| Model | `openclaw/main` (fixed) |
| Named Pipe | `\\.\pipe\openclaw-cc-push` |
| Pipe Server | `shared/cc_push_server.py` |
| Outbox | `shared/cc_outbox.md` |
| Stream mode | `stream: true` (hardcoded, mandatory) |

## Requirements

- PowerShell 7+
- Python 3.8+ (with pywin32 for pipe server)
- OpenClaw gateway running on localhost:18789
- Pipe server (`cc_push_server.py`) running for receive

## File Structure

```
call-assistant/
├── call_assistant.ps1              # Main script (v5.0.0)
├── SKILL.md                        # This file
├── _meta.json                      # Metadata
├── README.md                       # Project overview
├── install.ps1                     # One-click setup
├── .call-assistant.json.example    # Config template (optional)
├── shared/
│   ├── cc_push_server.py           # Pipe listener (小助理 → CC)
│   └── cc_outbox.md                # Outbox (shared with main repo)
└── test/
    └── smoke_test.ps1              # End-to-end validation
```

## Reliability

| Scenario | Behavior |
|----------|----------|
| Gateway healthy | Doorbell rings, 小助理 reads outbox, replies via pipe |
| Gateway timeout | Message safe in outbox. Escalate to 乾茂. |
| Gateway 401/403/503 | Do NOT retry. Escalate to 小助理 (proxy/key issue). |
| Pipe down | Auto-start via CreateFile check + restart. Max 1 retry. |
| Pipe restart fails | Outbox-only mode. Reply via outbox polling. |
| All channels down | Outbox written. Escalate to 乾茂. |

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 5.0.0 | 2026-06-15 | Architecture correction: outbox=primary message body, Gateway=doorbell only. Add English-only rule, receive flow docs, "正文不进Gateway" prohibition, stream:true mandatory, timeout rules, C5 sync, fault classification, pipe init decoupling. `Add-Content`→`Set-Content` fix in script. |
| 4.1.0 | 2026-06-11 | Token from openclaw.json, pipe CreateFile test, python PATH lookup |
| 4.0.0 | 2026-06-10 | Smoke test, glob char class fix, ContentType, SSE parse robustness |

## License

MIT
