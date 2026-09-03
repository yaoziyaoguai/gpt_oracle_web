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
probe_file="$test_root/oracle-web-live-probe.txt"
printf '%s\n' 'Harmless oracle-web attachment probe.' > "$probe_file"
slug="oracle-web-live-$(date +%Y%m%d-%H%M%S)-$$"

output="$($wrapper --force --timeout 5m --slug "$slug" \
  --browser-thinking-time "$level" \
  --browser-attachment-timeout 300s \
  --browser-attachments always \
  -p 'Read the harmless attachment. Reply with exactly ORACLE-WEB-LIVE-OK and nothing else.' \
  --file "$probe_file" 2>&1)"
printf '%s\n' "$output"

grep -Eq "$expected_position" <<< "$output" || {
  echo "Live test did not verify the expected five-position control" >&2
  exit 1
}
grep -q 'ORACLE-WEB-LIVE-OK' <<< "$output" || {
  echo "Live test did not capture the exact reply" >&2
  exit 1
}

echo "Live browser test passed"
