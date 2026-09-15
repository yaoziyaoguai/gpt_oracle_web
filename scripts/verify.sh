#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oracle-root)
      [[ $# -ge 2 ]] || oracle_web_die "--oracle-root requires a path"
      ORACLE_WEB_ORACLE_ROOT="$2"
      shift 2
      ;;
    --codex-home)
      [[ $# -ge 2 ]] || oracle_web_die "--codex-home requires a path"
      ORACLE_WEB_CODEX_HOME="$2"
      shift 2
      ;;
    --claude-home)
      [[ $# -ge 2 ]] || oracle_web_die "--claude-home requires a path"
      ORACLE_WEB_CLAUDE_HOME="$2"
      shift 2
      ;;
    --bin-dir)
      [[ $# -ge 2 ]] || oracle_web_die "--bin-dir requires a path"
      ORACLE_WEB_BIN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/verify.sh [--oracle-root PATH] [--codex-home PATH] [--claude-home PATH] [--bin-dir PATH]"
      exit 0
      ;;
    *)
      oracle_web_die "unknown option: $1"
      ;;
  esac
done

oracle_root="$(oracle_web_find_oracle_root || true)"
[[ -n "$oracle_root" ]] || oracle_web_die "could not locate @steipete/oracle; set ORACLE_WEB_ORACLE_ROOT"
oracle_web_validate_oracle_root "$oracle_root"

current_manifest="$(oracle_web_current_manifest "$oracle_root")"
state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
[[ "$state" == "patched" ]] || oracle_web_die "Oracle runtime state is $state, expected patched"

codex_home="$(oracle_web_default_codex_home)"
claude_home="${ORACLE_WEB_CLAUDE_HOME:-}"
bin_dir="$(oracle_web_default_bin_dir)"
skill_target="$codex_home/skills/oracle-web"
claude_skill_source="$ORACLE_WEB_REPO_ROOT/skill/claude-code/oracle-web"
claude_skill_target=""
if [[ -n "$claude_home" ]]; then
  claude_skill_target="$claude_home/skills/oracle-web"
fi
wrapper_target="$bin_dir/oracle-web"

cmp -s "$ORACLE_WEB_REPO_ROOT/bin/oracle-web" "$wrapper_target" || \
  oracle_web_die "installed wrapper is missing or differs: $wrapper_target"
diff -qr "$ORACLE_WEB_REPO_ROOT/skill/oracle-web" "$skill_target" >/dev/null || \
  oracle_web_die "installed Skill is missing or differs: $skill_target"
if [[ -n "$claude_skill_target" ]]; then
  cmp -s "$claude_skill_source/SKILL.md" "$claude_skill_target/SKILL.md" || \
    oracle_web_die "installed Claude Skill entry is missing or differs: $claude_skill_target/SKILL.md"
  cmp -s "$claude_skill_source/references/execution-advice.md" "$claude_skill_target/references/execution-advice.md" || \
    oracle_web_die "installed Claude execution advice is missing or differs: $claude_skill_target/references/execution-advice.md"
  cmp -s "$claude_skill_source/references/troubleshooting.md" "$claude_skill_target/references/troubleshooting.md" || \
    oracle_web_die "installed Claude troubleshooting reference is missing or differs: $claude_skill_target/references/troubleshooting.md"
fi

bash -n "$wrapper_target"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/install.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/verify.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/uninstall.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/test.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/live-smoke.sh"

grep -q '^name: oracle-web$' "$skill_target/SKILL.md" || oracle_web_die "Skill frontmatter name is invalid"
grep -q '^description:' "$skill_target/SKILL.md" || oracle_web_die "Skill frontmatter description is missing"
if [[ -n "$claude_skill_target" ]]; then
  grep -q '^name: oracle-web$' "$claude_skill_target/SKILL.md" || oracle_web_die "Claude Skill frontmatter name is invalid"
  grep -q '^description:' "$claude_skill_target/SKILL.md" || oracle_web_die "Claude Skill frontmatter description is missing"
  cmp -s "$ORACLE_WEB_REPO_ROOT/skill/oracle-web/references/troubleshooting.md" "$claude_skill_source/references/troubleshooting.md" || \
    oracle_web_die "Claude troubleshooting reference drifted from the shared browser failure contract"
fi

validator="$codex_home/skills/.system/skill-creator/scripts/quick_validate.py"
if [[ -f "$validator" ]] && command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 "$validator" "$skill_target"
  if [[ -n "$claude_skill_target" ]]; then
    python3 "$validator" "$claude_skill_target"
  fi
fi

echo "Verified gpt-oracle-web"
echo "  Oracle version: $ORACLE_WEB_SUPPORTED_VERSION"
echo "  Runtime state:  patched"
echo "  Skill:          $skill_target"
if [[ -n "$claude_skill_target" ]]; then
  echo "  Claude Skill:   $claude_skill_target"
fi
echo "  Wrapper:        $wrapper_target"
