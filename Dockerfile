# NemoClaw sandbox image — OpenClaw + NemoClaw plugin inside OpenShell
# LOOVE fork: configured for Anthropic Claude as primary inference provider.

FROM node:22-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        curl git ca-certificates \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Create sandbox user (matches OpenShell convention)
RUN groupadd -r sandbox && useradd -r -g sandbox -d /sandbox -s /bin/bash sandbox \
    && mkdir -p /sandbox/.openclaw /sandbox/.nemoclaw \
    && chown -R sandbox:sandbox /sandbox

# Install OpenClaw CLI
RUN npm install -g openclaw@2026.3.11

# Install PyYAML for blueprint runner
RUN pip3 install --break-system-packages pyyaml

# Copy our plugin and blueprint into the sandbox
COPY nemoclaw/dist/ /opt/nemoclaw/dist/
COPY nemoclaw/openclaw.plugin.json /opt/nemoclaw/
COPY nemoclaw/package.json /opt/nemoclaw/
COPY nemoclaw-blueprint/ /opt/nemoclaw-blueprint/

# Install runtime dependencies only (no devDependencies, no build step)
WORKDIR /opt/nemoclaw
RUN npm install --omit=dev

# Set up blueprint for local resolution
RUN mkdir -p /sandbox/.nemoclaw/blueprints/0.1.0 \
    && cp -r /opt/nemoclaw-blueprint/* /sandbox/.nemoclaw/blueprints/0.1.0/

# Copy startup script
COPY scripts/nemoclaw-start.sh /usr/local/bin/nemoclaw-start
RUN chmod +x /usr/local/bin/nemoclaw-start

WORKDIR /sandbox
USER sandbox

# Pre-create OpenClaw directories
RUN mkdir -p /sandbox/.openclaw/agents/main/agent \
    && chmod 700 /sandbox/.openclaw

# Write openclaw.json: LOOVE configuration with Anthropic Claude as primary
# provider. API keys are injected at runtime via environment variables.
RUN python3 -c "\
import json, os; \
config = { \
    'meta': { \
        'lastTouchedVersion': '2026.3.11', \
        'lastTouchedAt': '2026-03-18T00:00:00.000Z' \
    }, \
    'agents': { \
        'defaults': { \
            'model': { \
                'primary': 'anthropic/claude-opus-4-20250514', \
                'fallbacks': [ \
                    'anthropic/claude-sonnet-4-20250514', \
                    'moonshot/kimi-k2.5', \
                    'openai/gpt-4o' \
                ] \
            }, \
            'bootstrapMaxChars': 40000, \
            'bootstrapTotalMaxChars': 60000, \
            'thinkingDefault': 'medium' \
        } \
    }, \
    'commands': { \
        'native': 'auto', \
        'nativeSkills': 'auto' \
    }, \
    'gateway': { \
        'mode': 'local', \
        'controlUi': { \
            'dangerouslyDisableDeviceAuth': True, \
            'allowedOrigins': ['https://engine.loove.io'], \
            'allowInsecureAuth': True \
        }, \
        'trustedProxies': ['172.18.0.0/16', '172.17.0.0/16', '127.0.0.1', '::1'] \
    } \
}; \
path = os.path.expanduser('~/.openclaw/openclaw.json'); \
json.dump(config, open(path, 'w'), indent=2); \
os.chmod(path, 0o600)"

# Install NemoClaw plugin into OpenClaw
RUN openclaw doctor --fix > /dev/null 2>&1 || true \
    && openclaw plugins install /opt/nemoclaw > /dev/null 2>&1 || true

ENTRYPOINT ["/bin/bash"]
CMD []
