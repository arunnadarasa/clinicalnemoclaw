# NemoClaw + OpenClaw + Telegram — learnings (Clinical Hackathon)

Notes from end-to-end setup: install, gateway confusion, `nemoclaw` services, and Telegram allowlisting. Use this as a checklist so you repeat fewer mistakes than we did.

---

## What went wrong (failures / confusion)

### Installer and onboarding

- **Piping the install script into `bash` from an IDE or non-interactive runner** fails with `/dev/tty: Device not configured`. Interactive onboarding needs a real terminal, or set `NEMOCLAW_NON_INTERACTIVE=1` when supported.
- **Port `18789` conflicts** between the host OpenClaw gateway and NemoClaw’s SSH forward to the sandbox dashboard. Whatever listens on `127.0.0.1:18789` “wins”; the other must stop or use another port.
- **NVIDIA API key and RAM** matter for onboarding (OOM during image push is documented for low-memory hosts).

### Gateway dashboard and “token mismatch”

- **Pasting only part of the gateway token** (short hex) causes `unauthorized: gateway token mismatch`. The full token is long; copy from the full `openclaw dashboard --no-open` URL fragment `#token=…`.
- **Wrong mental model:** `http://127.0.0.1:18789` may be tunneled to the **sandbox** (OpenShell `-L` forward), not the **host** OpenClaw gateway. The token printed **on the Mac** matches the **host** config; the process behind the tunnel may be a **different** gateway. Align “where I run `openclaw` / where I get the token” with “what actually listens on 18789.”

### `nemoclaw` CLI location

- **`nemoclaw` is not available inside the sandbox shell** (`sandbox@…`). It runs on the **host**. Auxiliary services (`nemoclaw start`, `nemoclaw stop`, `nemoclaw status`) are host commands.

### `nemoclaw status` vs `nemoclaw start` (services)

- **Symptom:** `start` says “telegram-bridge already running” but `status` shows **stopped**.
- **Cause:** Service PID files live under `/tmp/nemoclaw-services-<SANDBOX_NAME>/`. `start` passes the **default sandbox name** (e.g. `clinical-hackathon`); older `status`/`stop` paths did not, and defaulted to `default`, so they looked at the wrong directory.
- **Fix upstream:** Ensure `status` and `stop` use the same `SANDBOX_NAME` as `start` (or always pass the default sandbox name). **Workaround:** `SANDBOX_NAME=your-sandbox bash …/start-services.sh --status`.

### Telegram allowlist

- **`ALLOWED_CHAT_IDS` is not a shell command** — it is an environment variable (`export ALLOWED_CHAT_IDS="…"`).
- **In zsh, odd errors** (e.g. `unknown file attribute`) can happen if a line has **parentheses** after `echo` without a proper comment start; keep commands simple (`printenv ALLOWED_CHAT_IDS`).
- **Critical:** The chat id from **“what Telegram / a bot helper says”** can differ from **`msg.chat.id`** for the **conversation your bot actually receives**. The bridge uses the **latter** for allowlisting.
- **Symptom:** Bot “does nothing” with allowlist enabled — often **`[ignored] chat … not in allowed list`** in `telegram-bridge.log`. The **number in that log line** is what must appear in `ALLOWED_CHAT_IDS` (including **negative** ids for many groups).

### Credentials vs environment

- **`TELEGRAM_BOT_TOKEN` / `NVIDIA_API_KEY`** may be read from `~/.nemoclaw/credentials.json` in some flows, but **`ALLOWED_CHAT_IDS` is only whatever is in the environment when the bridge process starts.** If you only put it in `~/.zshrc` but start services from a context that does not load it, the allowlist will not apply as expected.

---

## What worked / success

- **Official install:** `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash` (from a real terminal), then follow onboarding. Reference: [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw).
- **Telegram bridge:** `export TELEGRAM_BOT_TOKEN=…`, `export NVIDIA_API_KEY=…`, optional `export ALLOWED_CHAT_IDS=…`, then **`nemoclaw stop` / `nemoclaw start`** on the **host**. Docs: [Set Up the Telegram Bridge](https://docs.nvidia.com/nemoclaw/latest/deployment/set-up-telegram-bridge.html).
- **Debugging allowlist:** `tail -f /tmp/nemoclaw-services-<sandbox-name>/telegram-bridge.log` and use the **chat id the bridge logs** for `ALLOWED_CHAT_IDS`.
- **Isolation test:** `unset ALLOWED_CHAT_IDS` and restart services — if the bot responds, the allowlist values were wrong, not the bridge itself.
- **Egress policy:** `openshell term` when the sandbox needs network approvals.

---

## What we would do differently (playbook)

1. **Install and onboard only in Terminal.app / iTerm** (TTY), not from an IDE runner.
2. **Before trusting the dashboard:** run `lsof -i :18789` and know whether **SSH** (OpenShell forward) or **node** (host gateway) is listening.
3. **Always get gateway tokens** from `openclaw dashboard --no-open` for the **same environment** that serves that URL.
4. **Treat `nemoclaw` as host-only**; use `openclaw` inside the sandbox for agent chat.
5. **After any change to `ALLOWED_CHAT_IDS` or tokens:** `nemoclaw stop` && `nemoclaw start` from a shell where `printenv ALLOWED_CHAT_IDS` shows the intended value.
6. **For allowlists:** never trust a third-party “my id” unless it matches the id in **`telegram-bridge.log`** for the same chat you use.
7. **Persist secrets carefully:** `chmod 600` on files that hold tokens; avoid putting secrets in a repo; prefer a private `source ~/.nemoclaw-secrets` pattern over pasting tokens into public chats.

---

## Quick reference

| Issue | Where to look |
|--------|----------------|
| Bridge / Telegram | `/tmp/nemoclaw-services-<SANDBOX_NAME>/telegram-bridge.log` |
| Port 18789 | `lsof -i :18789` |
| Sandbox list | `nemoclaw list` / `nemoclaw status` |
| Egress | `openshell term` |

---

*This document reflects one hackathon path through [NemoClaw](https://github.com/NVIDIA/NemoClaw) and [clinicalnemoclaw](https://github.com/arunnadarasa/clinicalnemoclaw); APIs and behavior may change in alpha software.*
