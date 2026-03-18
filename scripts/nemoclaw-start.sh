#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw sandbox entrypoint (LOOVE fork). Configures OpenClaw with
# Anthropic Claude and starts the gateway inside the sandbox.
#
# Required env:
#   ANTHROPIC_API_KEY     API key for Anthropic Claude inference
#   OPENCLAW_GATEWAY_TOKEN  Gateway auth token
# Optional env:
#   OPENAI_API_KEY        Fallback OpenAI key
#   MOONSHOT_API_KEY       Fallback Moonshot/Kimi key
#   BRAVE_API_KEY          Brave search API key
#   CHAT_UI_URL            Browser origin for the forwarded dashboard

set -euo pipefail

NEMOCLAW_CMD=("$@")
CHAT_UI_URL="${CHAT_UI_URL:-http://127.0.0.1:18789}"
PUBLIC_PORT=18789

fix_openclaw_config() {
  python3 - <<'PYCFG'
import json
import os
from urllib.parse import urlparse

home = os.environ.get('HOME', '/sandbox')
config_path = os.path.join(home, '.openclaw', 'openclaw.json')
os.makedirs(os.path.dirname(config_path), exist_ok=True)

cfg = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        cfg = json.load(f)

# Preserve the LOOVE model config — do not override primary model
defaults = cfg.setdefault('agents', {}).setdefault('defaults', {})
if 'model' not in defaults:
    defaults['model'] = {
        'primary': 'anthropic/claude-opus-4-20250514',
        'fallbacks': [
            'anthropic/claude-sonnet-4-20250514',
            'moonshot/kimi-k2.5',
            'openai/gpt-4o'
        ]
    }

chat_ui_url = os.environ.get('CHAT_UI_URL', 'http://127.0.0.1:18789')
parsed = urlparse(chat_ui_url)
chat_origin = f"{parsed.scheme}://{parsed.netloc}" if parsed.scheme and parsed.netloc else 'http://127.0.0.1:18789'
local_origin = f'http://127.0.0.1:{os.environ.get("PUBLIC_PORT", "18789")}'
origins = [local_origin]
if chat_origin not in origins:
    origins.append(chat_origin)

gateway = cfg.setdefault('gateway', {})
gateway['mode'] = 'local'
gateway['controlUi'] = {
    'allowInsecureAuth': True,
    'dangerouslyDisableDeviceAuth': True,
    'allowedOrigins': origins,
}
gateway['trustedProxies'] = ['172.18.0.0/16', '172.17.0.0/16', '127.0.0.1', '::1']

# Inject gateway auth token from env if present
gateway_token = os.environ.get('OPENCLAW_GATEWAY_TOKEN', '')
if gateway_token:
    gateway['auth'] = {'mode': 'token', 'token': gateway_token}
    gateway['remote'] = {'token': gateway_token}

with open(config_path, 'w') as f:
    json.dump(cfg, f, indent=2)
os.chmod(config_path, 0o600)
PYCFG
}

write_auth_profile() {
  python3 - <<'PYAUTH'
import json
import os
path = os.path.expanduser('~/.openclaw/agents/main/agent/auth-profiles.json')
os.makedirs(os.path.dirname(path), exist_ok=True)
profiles = {}
if os.environ.get('ANTHROPIC_API_KEY'):
    profiles['anthropic:manual'] = {
        'type': 'api_key',
        'provider': 'anthropic',
        'keyRef': {'source': 'env', 'id': 'ANTHROPIC_API_KEY'},
        'profileId': 'anthropic:manual',
    }
if os.environ.get('OPENAI_API_KEY'):
    profiles['openai:manual'] = {
        'type': 'api_key',
        'provider': 'openai',
        'keyRef': {'source': 'env', 'id': 'OPENAI_API_KEY'},
        'profileId': 'openai:manual',
    }
if os.environ.get('MOONSHOT_API_KEY'):
    profiles['moonshot:manual'] = {
        'type': 'api_key',
        'provider': 'moonshot',
        'keyRef': {'source': 'env', 'id': 'MOONSHOT_API_KEY'},
        'profileId': 'moonshot:manual',
    }
if profiles:
    json.dump(profiles, open(path, 'w'))
    os.chmod(path, 0o600)
    print(f'[auth] wrote {len(profiles)} auth profile(s)')
else:
    print('[auth] WARNING: no API keys found in environment')
PYAUTH
}

print_dashboard_urls() {
  local token chat_ui_base local_url remote_url

  token="$(python3 - <<'PYTOKEN'
import json
import os
path = os.path.expanduser('~/.openclaw/openclaw.json')
try:
    cfg = json.load(open(path))
except Exception:
    print('')
else:
    print(cfg.get('gateway', {}).get('auth', {}).get('token', ''))
PYTOKEN
)"

  chat_ui_base="${CHAT_UI_URL%/}"
  local_url="http://127.0.0.1:${PUBLIC_PORT}/"
  remote_url="${chat_ui_base}/"
  if [ -n "$token" ]; then
    local_url="${local_url}#token=${token}"
    remote_url="${remote_url}#token=${token}"
  fi

  echo "[gateway] Local UI: ${local_url}"
  echo "[gateway] Remote UI: ${remote_url}"
}

start_auto_pair() {
  nohup python3 - <<'PYAUTOPAIR' >> /tmp/gateway.log 2>&1 &
import json
import subprocess
import time

DEADLINE = time.time() + 600
QUIET_POLLS = 0
APPROVED = 0

def run(*args):
    proc = subprocess.run(args, capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()

while time.time() < DEADLINE:
    rc, out, err = run('openclaw', 'devices', 'list', '--json')
    if rc != 0 or not out:
        time.sleep(1)
        continue
    try:
        data = json.loads(out)
    except Exception:
        time.sleep(1)
        continue

    pending = data.get('pending') or []
    paired = data.get('paired') or []
    has_browser = any((d.get('clientId') == 'openclaw-control-ui') or (d.get('clientMode') == 'webchat') for d in paired if isinstance(d, dict))

    if pending:
        QUIET_POLLS = 0
        for device in pending:
            request_id = (device or {}).get('requestId')
            if not request_id:
                continue
            arc, aout, aerr = run('openclaw', 'devices', 'approve', request_id, '--json')
            if arc == 0:
                APPROVED += 1
                print(f'[auto-pair] approved request={request_id}')
            elif aout or aerr:
                print(f'[auto-pair] approve failed request={request_id}: {(aerr or aout)[:400]}')
        time.sleep(1)
        continue

    if has_browser:
        QUIET_POLLS += 1
        if QUIET_POLLS >= 4:
            print(f'[auto-pair] browser pairing converged approvals={APPROVED}')
            break
    elif APPROVED > 0:
        QUIET_POLLS += 1
    else:
        QUIET_POLLS = 0

    time.sleep(1)
else:
    print(f'[auto-pair] watcher timed out approvals={APPROVED}')
PYAUTOPAIR
  echo "[gateway] auto-pair watcher launched (pid $!)"
}

echo 'Setting up NemoClaw (LOOVE fork)...'
openclaw doctor --fix > /dev/null 2>&1 || true
openclaw models set anthropic/claude-opus-4-20250514 > /dev/null 2>&1 || true
write_auth_profile
export CHAT_UI_URL PUBLIC_PORT
fix_openclaw_config
openclaw plugins install /opt/nemoclaw > /dev/null 2>&1 || true

if [ ${#NEMOCLAW_CMD[@]} -gt 0 ]; then
  exec "${NEMOCLAW_CMD[@]}"
fi

nohup openclaw gateway run > /tmp/gateway.log 2>&1 &
echo "[gateway] openclaw gateway launched (pid $!)"
start_auto_pair
print_dashboard_urls
