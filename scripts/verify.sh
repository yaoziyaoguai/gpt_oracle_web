#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"

oracle_root="$(oracle_web_find_oracle_root || true)"
[[ -n "$oracle_root" ]] || oracle_web_die "could not locate @steipete/oracle; set ORACLE_WEB_ORACLE_ROOT"
oracle_web_validate_oracle_root "$oracle_root"

state="$(oracle_web_patch_state "$oracle_root")"
[[ "$state" == "patched" ]] || oracle_web_die "Oracle runtime state is $state, expected patched"

codex_home="$(oracle_web_default_codex_home)"
bin_dir="$(oracle_web_default_bin_dir)"
skill_target="$codex_home/skills/oracle-web"
wrapper_target="$bin_dir/oracle-web"

cmp -s "$ORACLE_WEB_REPO_ROOT/bin/oracle-web" "$wrapper_target" || \
  oracle_web_die "installed wrapper is missing or differs: $wrapper_target"
diff -qr "$ORACLE_WEB_REPO_ROOT/skill/oracle-web" "$skill_target" >/dev/null || \
  oracle_web_die "installed Skill is missing or differs: $skill_target"

bash -n "$wrapper_target"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/install.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/verify.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/uninstall.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/test.sh"
bash -n "$ORACLE_WEB_REPO_ROOT/scripts/live-smoke.sh"

grep -q '^name: oracle-web$' "$skill_target/SKILL.md" || oracle_web_die "Skill frontmatter name is invalid"
grep -q '^description:' "$skill_target/SKILL.md" || oracle_web_die "Skill frontmatter description is missing"

validator="$codex_home/skills/.system/skill-creator/scripts/quick_validate.py"
if [[ -f "$validator" ]] && command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 "$validator" "$skill_target"
fi

echo "Verified gpt-oracle-web"
echo "  Oracle version: $ORACLE_WEB_SUPPORTED_VERSION"
echo "  Runtime state:  patched"
echo "  Skill:          $skill_target"
echo "  Wrapper:        $wrapper_target"
