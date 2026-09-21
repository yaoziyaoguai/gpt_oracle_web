#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"

if [[ "${ORACLE_WEB_LIVE_TEST:-}" != "1" ]]; then
  echo "Refusing to contact ChatGPT. Set ORACLE_WEB_LIVE_TEST=1 after reviewing this script." >&2
  exit 64
fi

wrapper="${ORACLE_WEB_WRAPPER:-$(command -v oracle-web || true)}"
if [[ -z "$wrapper" || ! -x "$wrapper" ]]; then
  echo "oracle-web wrapper not found" >&2
  exit 69
fi
state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
session_dir="${ORACLE_WEB_SESSION_DIR:-$state_root/oracle-web}"

level="${ORACLE_WEB_LIVE_LEVEL:-extra-high}"
case "$level" in
  extra-high)
    expected_position='(4 of 5|第 4 项，共 5 项)'
    ;;
  max)
    expected_position='(5 of 5|第 5 项，共 5 项)'
    ;;
  *)
    echo "ORACLE_WEB_LIVE_LEVEL must be extra-high or max" >&2
    exit 64
    ;;
esac

test_root="$(mktemp -d "${TMPDIR:-/tmp}/gpt-oracle-web-live.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
fixture="${ORACLE_WEB_LIVE_FIXTURE:-single}"
test_timeout=5m
probe_prompt='Read the harmless attachment material. Find the Reply token field. Reply with only its value, without quotes or formatting.'
probe_files=()
case "$fixture" in
  reasoning)
    test_timeout=45m
    probe_file="$test_root/route-problem.json"
    node --input-type=module - "$probe_file" <<'NODE'
import { writeFileSync } from 'node:fs';
const n = 11;
const costs = Array.from({length:n}, (_,i) => Array.from({length:n}, (_,j) => i === j ? 0 : 1 + ((i+3)*17+(j+5)*23+i*j*11)%89));
writeFileSync(process.argv[2], JSON.stringify({description:'Synthetic directed route problem: start at 0, visit nodes 1..10 exactly once, return to 0, minimize travel cost.', costs, precedence:[[1,3],[2,6],[5,8]]}));
NODE
    probe_files+=("$probe_file")
    probe_prompt='这是一次浏览器回答捕获测试，附件是人工生成的路线优化题，不包含真实项目或个人数据。请独立求解附件中的有向旅行商问题及先后约束，不需要并行分析。请给出最优路线、逐边费用核算，并说明如何确认全局最优（可给出 Held-Karp 动态规划状态、转移和实现代码；无法验证时请明确说明）。不要只返回思考标题或进度提示。完成论证后，用最后一行输出 RESULT {"cost":整数,"route":[0,...,0]}。没有人为等待要求，请正常完成推导。'
    ;;
  single)
    probe_file="$test_root/oracle-web-live-probe.txt"
    printf '%s\n' 'Harmless oracle-web attachment probe.' 'Reply token: ORACLE-WEB-LIVE-OK' > "$probe_file"
    probe_files+=("$probe_file")
    ;;
  multi|mixed-multi|bundle|large-bundle)
    file_count=14
    [[ "$fixture" == "multi" || "$fixture" == "mixed-multi" ]] && file_count=10
    for ((index = 1; index <= file_count; index += 1)); do
      if [[ "$fixture" == "mixed-multi" && "$index" -eq 1 ]]; then
        probe_file="$test_root/oracle-web-live-probe-with-a-long-markdown-filename-for-layout.md"
      elif [[ "$fixture" == "mixed-multi" ]]; then
        probe_file="$test_root/probe_$(printf '%02d' "$index").py"
      else
        probe_file="$test_root/oracle-web-live-probe-$index.txt"
      fi
      if [[ "$fixture" == "large-bundle" || "$fixture" == "mixed-multi" ]]; then
        awk -v file_index="$index" 'BEGIN { printf "Harmless bundle probe file %02d.\n", file_index; for (line = 1; line <= 900; line += 1) print "Harmless oracle attachment content." }' > "$probe_file"
      else
        printf 'Harmless bundle probe file %02d.\n' "$index" > "$probe_file"
      fi
      if [[ "$index" -eq 1 ]]; then
        printf '%s\n' 'Reply token: ORACLE-WEB-LIVE-OK' >> "$probe_file"
      fi
      probe_files+=("$probe_file")
    done
    ;;
  *)
    echo "ORACLE_WEB_LIVE_FIXTURE must be single, multi, mixed-multi, bundle, large-bundle, or reasoning" >&2
    exit 64
    ;;
esac
slug="ow-live-$(date +%Y%m%d-%H%M%S)-$$"
printf 'Live test session: %s\n' "$slug"
[[ "${#slug}" -le 36 ]] || oracle_web_die "generated live-test slug exceeds Oracle's 36-character limit"
oracle_args=(
  --force
  --timeout "$test_timeout"
  --browser-timeout "$test_timeout"
  --slug "$slug"
  --browser-thinking-time "$level"
  --browser-attachment-timeout 300s
  --browser-attachments always
  -p "$probe_prompt"
)
for probe_file in "${probe_files[@]}"; do
  oracle_args+=(--file "$probe_file")
done
if [[ "${ORACLE_WEB_LIVE_VERBOSE:-}" == "1" ]]; then
  oracle_args+=(--verbose)
fi

"$wrapper" --dry-run summary --files-report "${oracle_args[@]}"

set +e
"$wrapper" "${oracle_args[@]}" 2>&1 | tee "$test_root/oracle-output.log"
oracle_status=${PIPESTATUS[0]}
set -e
output="$(<"$test_root/oracle-output.log")"

cleanup_status=0
meta_file="$session_dir/sessions/$slug/meta.json"
if [[ -f "$meta_file" ]]; then
  (oracle_web_assert_session_cleanup "$session_dir" "$slug") || cleanup_status=$?
elif [[ "$oracle_status" -eq 0 ]]; then
  echo "Live test did not find metadata for its exact session: $slug" >&2
  cleanup_status=1
fi

if [[ "$oracle_status" -ne 0 ]]; then
  echo "Live Oracle invocation failed with exit $oracle_status" >&2
  exit "$oracle_status"
fi
if [[ "$cleanup_status" -ne 0 ]]; then
  echo "Live Oracle session cleanup verification failed" >&2
  exit "$cleanup_status"
fi

grep -Eq "$expected_position" <<< "$output" || {
  echo "Live test did not verify the expected five-position control" >&2
  exit 1
}
node --input-type=module - "$meta_file" "$expected_position" "$fixture" "${probe_files[0]}" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const meta = JSON.parse(readFileSync(process.argv[2], 'utf8'));
assert.equal(meta.status, 'completed', 'Session did not complete');
assert.equal(meta.browser?.modelSelection?.verified, true, 'Effort evidence was not persisted');
assert.match(meta.browser.modelSelection.resolvedLabel, new RegExp(process.argv[3]));
assert.equal(meta.browser?.runtime?.promptSubmitted, true, 'No send attempt recorded');
assert.match(meta.browser.runtime.tabUrl, /^https:\/\/chatgpt\.com\/c\/[^/?#]+/);
const transcript = meta.artifacts?.find(artifact => artifact.kind === 'transcript');
assert.ok(transcript, 'No saved answer artifact');
const saved = readFileSync(transcript.path, 'utf8');
const answer = saved.split('\n## Answer\n')[1]?.trim();
if (process.argv[4] === 'reasoning') {
  const result = JSON.parse(answer?.match(/RESULT\s*(\{[^\n]+\})/)?.[1] || 'null');
  assert.ok(result, 'No final structured result in saved answer');
  const {costs, precedence} = JSON.parse(readFileSync(process.argv[5], 'utf8'));
  assert.equal(result.cost, 153, 'Independent dynamic-programming optimum does not match');
  assert.equal(result.route.length, costs.length + 1);
  assert.equal(result.route[0], 0);
  assert.equal(result.route.at(-1), 0);
  assert.deepEqual([...result.route.slice(0,-1)].sort((a,b)=>a-b), costs.map((_,i)=>i));
  assert.equal(result.route.slice(1).reduce((sum,to,i)=>sum+costs[result.route[i]][to],0), result.cost);
  for (const [a,b] of precedence) assert.ok(result.route.indexOf(a) < result.route.indexOf(b));
  assert.ok(answer.length > 500, 'Captured only a short result rather than the requested explanation');
} else {
  assert.equal(answer, 'ORACLE-WEB-LIVE-OK', 'Saved assistant answer did not contain the attachment token');
}
console.log('Completed metadata, effort evidence and saved answer verified');
NODE

echo "Live browser test passed"
