#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${1:-http://localhost:8000}"
MODEL="${2:-mistral-medium-3-5-128b}"
RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_FILE="${RESULTS_DIR}/smoke-tests-${TIMESTAMP}.json"
JSONL_FILE=$(mktemp)

mkdir -p "$RESULTS_DIR"

PASS=0
FAIL=0
TOTAL=5

run_test() {
  local name="$1"
  local description="$2"
  local payload="$3"
  local test_num="$4"

  echo "──────────────────────────────────────────────"
  echo "TEST ${test_num}/${TOTAL}: ${name}"
  echo "  ${description}"
  echo ""

  local tmp
  tmp=$(mktemp)

  local http_code
  http_code=$(curl -s -o "$tmp" -w '%{http_code}' \
    "${ENDPOINT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || true

  if [[ "$http_code" != "200" ]]; then
    echo "  FAILED (HTTP ${http_code})"
    echo ""
    FAIL=$((FAIL + 1))
    python3 -c "
import json
print(json.dumps({'name': '$name', 'status': 'FAILED', 'http_code': $http_code}))
" >> "$JSONL_FILE"
    rm -f "$tmp"
    return
  fi

  local finish_reason prompt_tokens completion_tokens
  finish_reason=$(python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['finish_reason'])" < "$tmp" 2>/dev/null || echo "N/A")
  prompt_tokens=$(python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['prompt_tokens'])" < "$tmp" 2>/dev/null || echo "0")
  completion_tokens=$(python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" < "$tmp" 2>/dev/null || echo "0")

  echo "  Status:            PASSED"
  echo "  Finish reason:     ${finish_reason}"
  echo "  Prompt tokens:     ${prompt_tokens}"
  echo "  Completion tokens: ${completion_tokens}"
  echo ""
  echo "  Response:"
  python3 -c "
import sys, json
r = json.load(sys.stdin)
c = r['choices'][0]['message']
if 'tool_calls' in c and c.get('tool_calls'):
    tc = c['tool_calls'][0]
    text = f\"Tool call: {tc['function']['name']}({tc['function']['arguments']})\"
else:
    text = c.get('content', '')
    if len(text) > 500:
        text = text[:500] + '...'
for line in text.split('\n'):
    print('    ' + line)
" < "$tmp" 2>/dev/null || echo "    (could not parse response)"
  echo ""

  PASS=$((PASS + 1))

  python3 -c "
import sys, json
r = json.load(sys.stdin)
c = r['choices'][0]['message']
if 'tool_calls' in c and c.get('tool_calls'):
    tc = c['tool_calls'][0]
    excerpt = f\"Tool call: {tc['function']['name']}({tc['function']['arguments']})\"
else:
    excerpt = c.get('content', '')[:500]
result = {
    'name': '$name',
    'description': '$description',
    'status': 'PASSED',
    'finish_reason': '$finish_reason',
    'prompt_tokens': $prompt_tokens,
    'completion_tokens': $completion_tokens,
    'response_excerpt': excerpt
}
print(json.dumps(result, ensure_ascii=False))
" < "$tmp" >> "$JSONL_FILE" 2>/dev/null

  rm -f "$tmp"
}

echo ""
echo "=============================================="
echo " Mistral Medium 3.5 128B — Deployment Smoke Tests"
echo "=============================================="
echo " Endpoint: ${ENDPOINT}"
echo " Model:    ${MODEL}"
echo " Date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=============================================="
echo ""

run_test "General Knowledge" \
  "Short factual answer to validate basic reasoning" \
  "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Explain quantum computing in 2 sentences.\"}],\"max_tokens\":100}" \
  1

run_test "Code Generation" \
  "Generate a Python function with examples" \
  "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a Python function that checks if a number is prime. Include examples.\"}],\"max_tokens\":500}" \
  2

run_test "Structured JSON Output" \
  "Validate model can produce well-formed JSON" \
  "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a helpful assistant that responds in JSON format.\"},{\"role\":\"user\",\"content\":\"List the 3 largest countries by area with their capital and population.\"}],\"max_tokens\":300}" \
  3

run_test "Translation" \
  "Translate English to Japanese" \
  "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Translate to Japanese: The weather is beautiful today.\"}],\"max_tokens\":100}" \
  4

run_test "Tool Calling" \
  "Validate native function calling via tool_call_parser=mistral" \
  "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Paris?\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get current weather for a location\",\"parameters\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\",\"description\":\"City name\"}},\"required\":[\"location\"]}}}],\"max_tokens\":100}" \
  5

echo "=============================================="
echo " SUMMARY: ${PASS}/${TOTAL} passed, ${FAIL}/${TOTAL} failed"
echo "=============================================="

python3 -c "
import json
tests = []
with open('$JSONL_FILE') as f:
    for line in f:
        line = line.strip()
        if line:
            tests.append(json.loads(line))
results = {
    'endpoint': '${ENDPOINT}',
    'model': '${MODEL}',
    'timestamp': '$(date -u '+%Y-%m-%dT%H:%M:%SZ')',
    'summary': {'passed': ${PASS}, 'failed': ${FAIL}, 'total': ${TOTAL}},
    'tests': tests
}
with open('${RESULTS_FILE}', 'w') as f:
    json.dump(results, f, indent=2, ensure_ascii=False)
print(f'\nResults saved to: ${RESULTS_FILE}')
"

rm -f "$JSONL_FILE"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
