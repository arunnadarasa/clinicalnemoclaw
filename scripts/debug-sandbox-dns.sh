#!/usr/bin/env bash
# Run on the host (Mac/Linux) with `openshell` in PATH.
# Collects DNS/HTTPS evidence from a NemoClaw sandbox for debugging EAI_AGAIN / web_fetch.
#
# Usage: ./scripts/debug-sandbox-dns.sh [SANDBOX_NAME]
# Env:   DEBUG_LOG_PATH (default: ./debug-sandbox-dns.ndjson in cwd)
#        INGEST_ENDPOINT (optional; if set, POSTs NDJSON lines for local tooling)
#        DEBUG_SESSION_ID, DEBUG_RUN_ID (optional metadata)
set -euo pipefail
SANDBOX_NAME="${1:-clinical-hackathon}"
LOG="${DEBUG_LOG_PATH:-$PWD/debug-sandbox-dns.ndjson}"
SESSION_ID="${DEBUG_SESSION_ID:-sandbox-dns}"
RUN_ID="${DEBUG_RUN_ID:-run-$(date +%s)}"
ENDPOINT="${INGEST_ENDPOINT:-}"
OUT=$(mktemp)

mkdir -p "$(dirname "$LOG")"

CONF=$(mktemp)
trap 'rm -f "$CONF" "$OUT"' EXIT
export PATH="${HOME}/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
openshell sandbox ssh-config "$SANDBOX_NAME" >"$CONF"
HOST_ALIAS="openshell-${SANDBOX_NAME}"

ssh -F "$CONF" -o BatchMode=yes -o ConnectTimeout=15 "$HOST_ALIAS" 'bash -s' >"$OUT" 2>&1 <<'REMOTE'
set +e
echo "=== /etc/resolv.conf ==="
cat /etc/resolv.conf 2>&1
echo "resolv_exit=$?"
echo "=== getent hosts www.gov.uk ==="
getent hosts www.gov.uk 2>&1
echo "getent_exit=$?"
echo "=== python socket.getaddrinfo www.gov.uk:443 ==="
python3 -c "import socket
try:
  print(socket.getaddrinfo('www.gov.uk', 443, type=socket.SOCK_STREAM))
except Exception as e:
  print(type(e).__name__, str(e))" 2>&1
echo "py_exit=$?"
echo "=== curl https://www.gov.uk/ (via proxy env) ==="
curl -sS -o /dev/null -w 'http_code=%{http_code}\n' --connect-timeout 8 --max-time 20 "https://www.gov.uk/" 2>&1
echo "curl_exit=$?"
echo "=== curl --noproxy '*' https://www.gov.uk/ (direct TLS) ==="
curl -sS -o /dev/null -w 'http_code=%{http_code}\n' --noproxy '*' --connect-timeout 8 --max-time 20 "https://www.gov.uk/" 2>&1
echo "curl_nopx_exit=$?"
echo "=== dig short ==="
command -v dig >/dev/null && dig @10.43.0.10 www.gov.uk +short +time=2 || echo "no_dig"
echo "=== nsswitch ==="
head -5 /etc/nsswitch.conf 2>&1
echo "=== proxy env ==="
env | grep -iE '^(http|https|all|no)_proxy=' 2>&1 || true
REMOTE

export LOG SESSION_ID RUN_ID ENDPOINT OUT
python3 <<'PY'
import json, os, subprocess, time
log = os.environ["LOG"]
session = os.environ["SESSION_ID"]
run = os.environ["RUN_ID"]
endpoint = os.environ.get("ENDPOINT") or ""
with open(os.environ["OUT"], "r", encoding="utf-8", errors="replace") as f:
    raw = f.read()

def emit(hid, loc, msg, data):
    line = {
        "sessionId": session,
        "runId": run,
        "hypothesisId": hid,
        "location": loc,
        "message": msg,
        "data": data,
        "timestamp": int(time.time() * 1000),
    }
    s = json.dumps(line, ensure_ascii=False)
    with open(log, "a", encoding="utf-8") as f:
        f.write(s + "\n")
    if endpoint:
        try:
            subprocess.run(
                ["curl", "-sS", "-X", "POST", endpoint, "-H", "Content-Type: application/json",
                 "-H", f"X-Debug-Session-Id: {session}", "--data-binary", s],
                capture_output=True,
                timeout=5,
            )
        except Exception:
            pass

emit("H1", "sandbox:/etc/resolv.conf", "resolver config", {"raw": raw[:2500]})
emit("H2", "sandbox:getent", "libc NSS for www.gov.uk", {"raw": raw})
emit("H3", "sandbox:python_getaddrinfo", "same API as Node DNS", {"raw": raw})
emit("H4", "sandbox:curl_https", "TCP/TLS after DNS", {"raw": raw})
emit("H5", "sandbox:nsswitch", "nsswitch", {"raw": raw})
emit("H6", "sandbox:proxy_env", "HTTP(S)_PROXY", {"raw": raw})
PY

echo "--- appended NDJSON → $LOG ($(wc -c < "$OUT") bytes from sandbox)"
