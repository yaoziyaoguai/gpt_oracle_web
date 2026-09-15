#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"

force=false
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
    --state-dir)
      [[ $# -ge 2 ]] || oracle_web_die "--state-dir requires a path"
      ORACLE_WEB_STATE_DIR="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    -h|--help)
      echo "Usage: scripts/uninstall.sh [--oracle-root PATH] [--codex-home PATH] [--claude-home PATH] [--bin-dir PATH] [--state-dir PATH] [--force]"
      exit 0
      ;;
    *)
      oracle_web_die "unknown option: $1"
      ;;
  esac
done

oracle_root="$(oracle_web_find_oracle_root || true)"
[[ -n "$oracle_root" ]] || oracle_web_die "could not locate @steipete/oracle; pass --oracle-root"
oracle_web_validate_oracle_root "$oracle_root"

codex_home="$(oracle_web_default_codex_home)"
claude_home="${ORACLE_WEB_CLAUDE_HOME:-}"
bin_dir="$(oracle_web_default_bin_dir)"
state_dir="$(oracle_web_default_state_dir)"
skill_source="$ORACLE_WEB_REPO_ROOT/skill/oracle-web"
skill_target="$codex_home/skills/oracle-web"
claude_skill_source="$ORACLE_WEB_REPO_ROOT/skill/claude-code/oracle-web"
claude_skill_target=""
if [[ -n "$claude_home" ]]; then
  claude_skill_target="$claude_home/skills/oracle-web"
fi
wrapper_source="$ORACLE_WEB_REPO_ROOT/bin/oracle-web"
wrapper_target="$bin_dir/oracle-web"

assert_managed_file_removable() {
  local source="$1"
  local target="$2"
  [[ -e "$target" ]] || return
  if ! cmp -s "$source" "$target" && [[ "$force" != true ]]; then
    oracle_web_die "$target was modified after installation; refusing a partial uninstall without --force"
  fi
}

assert_managed_file_removable "$wrapper_source" "$wrapper_target"
assert_managed_file_removable "$skill_source/SKILL.md" "$skill_target/SKILL.md"
assert_managed_file_removable "$skill_source/agents/openai.yaml" "$skill_target/agents/openai.yaml"
assert_managed_file_removable "$skill_source/references/execution-advice.md" "$skill_target/references/execution-advice.md"
assert_managed_file_removable "$skill_source/references/troubleshooting.md" "$skill_target/references/troubleshooting.md"
if [[ -n "$claude_skill_target" ]]; then
  assert_managed_file_removable "$claude_skill_source/SKILL.md" "$claude_skill_target/SKILL.md"
  assert_managed_file_removable "$claude_skill_source/references/execution-advice.md" "$claude_skill_target/references/execution-advice.md"
  assert_managed_file_removable "$claude_skill_source/references/troubleshooting.md" "$claude_skill_target/references/troubleshooting.md"
fi

current_manifest="$(oracle_web_current_manifest "$oracle_root")"
patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
case "$patch_state" in
  patched)
    patch -C -R -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_PATCH_FILE" >/dev/null
    patch -R -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_PATCH_FILE" >/dev/null
    [[ "$(oracle_web_patch_state "$oracle_root" "$current_manifest")" == "pristine" ]] || \
      oracle_web_die "runtime rollback verification failed"
    ;;
  pristine)
    ;;
  mixed|unknown)
    oracle_web_die "Oracle runtime has unrecognized changes; refusing automatic rollback"
    ;;
esac

remove_managed_file() {
  local source="$1"
  local target="$2"
  [[ -e "$target" ]] || return
  if cmp -s "$source" "$target" || [[ "$force" == true ]]; then
    rm -f "$target"
  else
    echo "Preserved modified file: $target" >&2
  fi
}

remove_managed_file "$wrapper_source" "$wrapper_target"
remove_managed_file "$skill_source/SKILL.md" "$skill_target/SKILL.md"
remove_managed_file "$skill_source/agents/openai.yaml" "$skill_target/agents/openai.yaml"
remove_managed_file "$skill_source/references/execution-advice.md" "$skill_target/references/execution-advice.md"
remove_managed_file "$skill_source/references/troubleshooting.md" "$skill_target/references/troubleshooting.md"
rmdir "$skill_target/agents" "$skill_target/references" "$skill_target" 2>/dev/null || true
if [[ -n "$claude_skill_target" ]]; then
  remove_managed_file "$claude_skill_source/SKILL.md" "$claude_skill_target/SKILL.md"
  remove_managed_file "$claude_skill_source/references/execution-advice.md" "$claude_skill_target/references/execution-advice.md"
  remove_managed_file "$claude_skill_source/references/troubleshooting.md" "$claude_skill_target/references/troubleshooting.md"
  rmdir "$claude_skill_target/references" "$claude_skill_target" 2>/dev/null || true
fi
rm -f "$state_dir/install-receipt.tsv"

echo "Uninstalled gpt-oracle-web"
echo "  Oracle runtime: restored to pristine $ORACLE_WEB_SUPPORTED_VERSION"
