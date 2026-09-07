#!/usr/bin/env bash
set -euo pipefail

if [[ "${ORACLE_WEB_LIVE_TEST:-}" != "1" ]]; then
  echo "Refusing to contact ChatGPT. Set ORACLE_WEB_LIVE_TEST=1 after reviewing this script." >&2
  exit 64
fi

wrapper="${ORACLE_WEB_WRAPPER:-$(command -v oracle-web || true)}"
if [[ -z "$wrapper" || ! -x "$wrapper" ]]; then
  echo "oracle-web wrapper not found" >&2
  exit 69
fi

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
probe_files=()
case "$fixture" in
  single)
    probe_file="$test_root/oracle-web-live-probe.txt"
    printf '%s\n' 'Harmless oracle-web attachment probe.' > "$probe_file"
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
      probe_files+=("$probe_file")
    done
    ;;
  *)
    echo "ORACLE_WEB_LIVE_FIXTURE must be single, multi, mixed-multi, bundle, or large-bundle" >&2
    exit 64
    ;;
esac
slug="oracle-web-live-$(date +%Y%m%d-%H%M%S)-$$"
oracle_args=(
  --force
  --timeout 5m
  --slug "$slug"
  --browser-thinking-time "$level"
  --browser-attachment-timeout 300s
  --browser-attachments always
  -p 'Read the harmless attachment material. Reply with exactly ORACLE-WEB-LIVE-OK and nothing else.'
)
for probe_file in "${probe_files[@]}"; do
  oracle_args+=(--file "$probe_file")
done
if [[ "${ORACLE_WEB_LIVE_VERBOSE:-}" == "1" ]]; then
  oracle_args+=(--verbose)
fi

"$wrapper" --dry-run summary --files-report "${oracle_args[@]}"

set +e
output="$($wrapper "${oracle_args[@]}" 2>&1)"
oracle_status=$?
set -e
printf '%s\n' "$output"

if [[ "$oracle_status" -ne 0 ]]; then
  echo "Live Oracle invocation failed with exit $oracle_status" >&2
  exit "$oracle_status"
fi

grep -Eq "$expected_position" <<< "$output" || {
  echo "Live test did not verify the expected five-position control" >&2
  exit 1
}
grep -q 'ORACLE-WEB-LIVE-OK' <<< "$output" || {
  echo "Live test did not capture the exact reply" >&2
  exit 1
}

echo "Live browser test passed"
