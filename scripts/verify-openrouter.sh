#!/usr/bin/env bash
# =============================================================================
# Verify Claude is actually reachable through this app's OpenRouter path
# =============================================================================
# server/_shared/llm.ts force-injects OPENROUTER_PROVIDER_ROUTING into the
# `provider` field of EVERY OpenRouter request:
#
#     extraBody: {
#       ...(overrides.enableReasoning ? {} : { reasoning: { enabled: false } }),
#       provider: OPENROUTER_PROVIDER_ROUTING,
#     }
#
# with a comment saying the exclusion "is not optional". If that object uses
# `only:` (an allow-list) without "anthropic", or pins `order:` with
# `allow_fallbacks: false` to a DeepSeek-serving backend, your Claude model
# string will fail or silently misroute — and the chain will quietly fall back
# to Groq. Telemetry would show it, but only after you'd been billed.
#
# Run this BEFORE deploying the OpenRouter config.
# =============================================================================
set -euo pipefail

: "${OPENROUTER_API_KEY:?Set OPENROUTER_API_KEY first}"
MODEL="${MODEL:-anthropic/claude-sonnet-4.5}"

echo "=== 1. The routing constant this app injects ==="
if [[ -f scripts/_llm-model-timeouts.mjs ]]; then
  grep -A25 "OPENROUTER_PROVIDER_ROUTING" scripts/_llm-model-timeouts.mjs || \
    echo "  !! constant not found — check the export name"
else
  echo "  !! Run this from the worldmonitor repo root."
  exit 1
fi

echo
echo "=== 2. Is the model listed on your account? ==="
curl -s https://openrouter.ai/api/v1/models \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
| python3 -c "
import json,sys,os
m=os.environ.get('MODEL','anthropic/claude-sonnet-4.5')
d=json.load(sys.stdin).get('data',[])
hit=[x for x in d if x.get('id')==m]
if hit:
    x=hit[0]
    print(f\"  FOUND {x['id']}  ctx={x.get('context_length')}\")
    print(f\"  pricing: {x.get('pricing')}\")
else:
    print(f'  NOT FOUND: {m}')
    print('  Available Anthropic models:')
    for x in d:
        if x.get('id','').startswith('anthropic/'):
            print('   ', x['id'])
"

echo
echo "=== 3. Credit balance ==="
curl -s https://openrouter.ai/api/v1/credits \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" | python3 -m json.tool 2>/dev/null \
  || echo "  (endpoint shape may have changed — check the dashboard)"

echo
echo "=== 4. Live call, WITHOUT the app's routing constraint ==="
curl -s https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://worldmonitor.app" \
  -H "X-Title: World Monitor" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":16}" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print('  ERROR:', d['error'])
else:
    c=d.get('choices',[{}])[0]
    print('  content:', repr(c.get('message',{}).get('content')))
    print('  finish_reason:', c.get('finish_reason'))
    print('  usage:', d.get('usage'))
"

echo
echo "=== 5. Same call WITH the app's routing constraint ==="
echo "  Paste the OPENROUTER_PROVIDER_ROUTING object from step 1 into the"
echo "  'provider' field below and re-run manually. If step 4 succeeds and"
echo "  this fails, the routing constant is the blocker and you need to"
echo "  fork _llm-model-timeouts.mjs to widen it for Anthropic models."
echo
cat <<'EOF'
  curl -s https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL}"'",
      "messages": [{"role":"user","content":"Reply with exactly: OK"}],
      "max_tokens": 16,
      "provider": { <<< PASTE THE CONSTANT HERE >>> }
    }' | python3 -m json.tool
EOF
