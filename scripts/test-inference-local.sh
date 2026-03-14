#!/usr/bin/env bash
# Test inference.local routing through OpenShell provider (local Ollama)
echo '{"model":"nemotron-mini","messages":[{"role":"user","content":"say hello"}]}' > /tmp/req.json
curl -s https://inference.local/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/req.json
