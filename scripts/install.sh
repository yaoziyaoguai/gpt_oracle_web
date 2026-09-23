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
      echo "Usage: scripts/install.sh [--oracle-root PATH] [--codex-home PATH] [--claude-home PATH] [--bin-dir PATH] [--state-dir PATH] [--force]"
      exit 0
      ;;
    *)
      oracle_web_die "unknown option: $1"
      ;;
  esac
done

command -v node >/dev/null 2>&1 || oracle_web_die "Node.js is required"
command -v patch >/dev/null 2>&1 || oracle_web_die "patch is required"
command -v shasum >/dev/null 2>&1 || oracle_web_die "shasum is required"

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

wrapper_conflict=false
skill_conflict=false
claude_skill_conflict=false
if [[ -e "$wrapper_target" && ! "$wrapper_target" -ef "$wrapper_source" ]] && ! cmp -s "$wrapper_source" "$wrapper_target"; then
  wrapper_conflict=true
  [[ "$force" == true ]] || oracle_web_die "$wrapper_target already exists and differs; rerun with --force after reviewing it"
fi
if [[ -d "$skill_target" ]] && ! diff -qr "$skill_source" "$skill_target" >/dev/null 2>&1; then
  skill_conflict=true
  [[ "$force" == true ]] || oracle_web_die "$skill_target already exists and differs; rerun with --force after reviewing it"
fi
if [[ -n "$claude_skill_target" && -d "$claude_skill_target" ]] && {
  ! cmp -s "$claude_skill_source/SKILL.md" "$claude_skill_target/SKILL.md" ||
  ! cmp -s "$claude_skill_source/references/execution-advice.md" "$claude_skill_target/references/execution-advice.md" ||
  ! cmp -s "$claude_skill_source/references/troubleshooting.md" "$claude_skill_target/references/troubleshooting.md"
}; then
  claude_skill_conflict=true
  [[ "$force" == true ]] || oracle_web_die "$claude_skill_target already exists and differs; rerun with --force after reviewing it"
fi

mkdir -p "$state_dir"
if [[ "$force" == true && ("$wrapper_conflict" == true || "$skill_conflict" == true || "$claude_skill_conflict" == true) ]]; then
  backup_dir="$state_dir/backups/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$backup_dir"
  if [[ "$wrapper_conflict" == true ]]; then
    cp "$wrapper_target" "$backup_dir/oracle-web"
  fi
  if [[ "$skill_conflict" == true ]]; then
    cp -R "$skill_target" "$backup_dir/oracle-web-skill"
  fi
  if [[ "$claude_skill_conflict" == true ]]; then
    cp -R "$claude_skill_target" "$backup_dir/oracle-web-claude-skill"
  fi
  echo "Backed up replaced files to $backup_dir"
fi

current_manifest="$(oracle_web_current_manifest "$oracle_root")"
patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_DA31C46_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_DA31C46_HASH_MANIFEST" && \
      -f "$ORACLE_WEB_DA31C46_NPM_HASH_MANIFEST" ]] && {
  [[ "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_DA31C46_HASH_MANIFEST")" == "patched" ]] ||
  [[ "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_DA31C46_NPM_HASH_MANIFEST")" == "patched" ]]
}; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_DA31C46_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_DA31C46_UPGRADE_PATCH" >/dev/null
  current_manifest="$(oracle_web_current_manifest "$oracle_root")"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision da31c46 did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision da31c46"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_E13EA4C_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_E13EA4C_HASH_MANIFEST" && \
      -f "$ORACLE_WEB_E13EA4C_NPM_HASH_MANIFEST" ]] && {
  [[ "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_E13EA4C_HASH_MANIFEST")" == "patched" ]] ||
  [[ "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_E13EA4C_NPM_HASH_MANIFEST")" == "patched" ]]
}; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_E13EA4C_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_E13EA4C_UPGRADE_PATCH" >/dev/null
  current_manifest="$(oracle_web_current_manifest "$oracle_root")"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision e13ea4c did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision e13ea4c"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_A6D4E88_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_A6D4E88_HASH_MANIFEST" && \
      -f "$ORACLE_WEB_A6D4E88_NPM_HASH_MANIFEST" ]] && {
  [[ "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_A6D4E88_HASH_MANIFEST")" == "patched" ]] ||
  [[ "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_A6D4E88_NPM_HASH_MANIFEST")" == "patched" ]]
}; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_A6D4E88_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_A6D4E88_UPGRADE_PATCH" >/dev/null
  current_manifest="$(oracle_web_current_manifest "$oracle_root")"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision a6d4e88 did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision a6d4e88"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_F86C4FC_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_F86C4FC_HASH_MANIFEST" && \
      "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_F86C4FC_HASH_MANIFEST")" == "patched" ]]; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_F86C4FC_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_F86C4FC_UPGRADE_PATCH" >/dev/null
  current_manifest="$ORACLE_WEB_HASH_MANIFEST"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision f86c4fc did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision f86c4fc"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_38F4BFF_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_38F4BFF_HASH_MANIFEST" && \
      "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_38F4BFF_HASH_MANIFEST")" == "patched" ]]; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_38F4BFF_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_38F4BFF_UPGRADE_PATCH" >/dev/null
  current_manifest="$ORACLE_WEB_HASH_MANIFEST"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision 38f4bff did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision 38f4bff"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_042D57F_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_042D57F_HASH_MANIFEST" && \
      "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_042D57F_HASH_MANIFEST")" == "patched" ]]; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_042D57F_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_042D57F_UPGRADE_PATCH" >/dev/null
  current_manifest="$ORACLE_WEB_HASH_MANIFEST"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision 042d57f did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision 042d57f"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_2FE5969_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_2FE5969_HASH_MANIFEST" && \
      "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_2FE5969_HASH_MANIFEST")" == "patched" ]]; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_2FE5969_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_2FE5969_UPGRADE_PATCH" >/dev/null
  current_manifest="$ORACLE_WEB_HASH_MANIFEST"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision 2fe5969 did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision 2fe5969"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_209F3BA_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_209F3BA_HASH_MANIFEST" && \
      "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_209F3BA_HASH_MANIFEST")" == "patched" ]]; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_209F3BA_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_209F3BA_UPGRADE_PATCH" >/dev/null
  current_manifest="$ORACLE_WEB_HASH_MANIFEST"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision 209f3ba did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision 209f3ba"
fi
if [[ "$patch_state" == "unknown" && \
      -f "$ORACLE_WEB_F0EA8D6_UPGRADE_PATCH" && \
      -f "$ORACLE_WEB_F0EA8D6_HASH_MANIFEST" && \
      "$(oracle_web_patch_state "$oracle_root" "$ORACLE_WEB_F0EA8D6_HASH_MANIFEST")" == "patched" ]]; then
  patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_F0EA8D6_UPGRADE_PATCH" >/dev/null
  patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_F0EA8D6_UPGRADE_PATCH" >/dev/null
  current_manifest="$ORACLE_WEB_HASH_MANIFEST"
  patch_state="$(oracle_web_patch_state "$oracle_root" "$current_manifest")"
  [[ "$patch_state" == "patched" ]] || \
    oracle_web_die "upgrade from managed revision f0ea8d6 did not reach the current patched state"
  echo "Upgraded Oracle runtime from managed revision f0ea8d6"
fi
case "$patch_state" in
  pristine)
    patch -C -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_PATCH_FILE" >/dev/null
    patch -f -p1 -d "$oracle_root" -i "$ORACLE_WEB_PATCH_FILE" >/dev/null
    [[ "$(oracle_web_patch_state "$oracle_root" "$current_manifest")" == "patched" ]] || \
      oracle_web_die "runtime patch verification failed"
    ;;
  patched)
    ;;
  mixed|unknown)
    oracle_web_die "Oracle runtime differs from both the supported pristine and patched states; refusing to overwrite it"
    ;;
esac

mkdir -p "$bin_dir" "$skill_target/agents" "$skill_target/references" "$state_dir"
install -m 0755 "$wrapper_source" "$wrapper_target"
install -m 0644 "$skill_source/SKILL.md" "$skill_target/SKILL.md"
install -m 0644 "$skill_source/agents/openai.yaml" "$skill_target/agents/openai.yaml"
install -m 0644 "$skill_source/references/execution-advice.md" "$skill_target/references/execution-advice.md"
install -m 0644 "$skill_source/references/troubleshooting.md" "$skill_target/references/troubleshooting.md"
if [[ -n "$claude_skill_target" ]]; then
  mkdir -p "$claude_skill_target/references"
  install -m 0644 "$claude_skill_source/SKILL.md" "$claude_skill_target/SKILL.md"
  install -m 0644 "$claude_skill_source/references/execution-advice.md" "$claude_skill_target/references/execution-advice.md"
  install -m 0644 "$claude_skill_source/references/troubleshooting.md" "$claude_skill_target/references/troubleshooting.md"
fi

receipt="$state_dir/install-receipt.tsv"
{
  printf 'oracle_root\t%s\n' "$oracle_root"
  printf 'skill_dir\t%s\n' "$skill_target"
  if [[ -n "$claude_skill_target" ]]; then
    printf 'claude_skill_dir\t%s\n' "$claude_skill_target"
  fi
  printf 'wrapper\t%s\n' "$wrapper_target"
  printf 'version\t%s\n' "$ORACLE_WEB_SUPPORTED_VERSION"
} > "$receipt"

echo "Installed gpt-oracle-web"
echo "  Oracle runtime: $oracle_root (patched and verified)"
echo "  Skill:          $skill_target"
if [[ -n "$claude_skill_target" ]]; then
  echo "  Claude Skill:   $claude_skill_target"
fi
echo "  Wrapper:        $wrapper_target"
echo "  Receipt:        $receipt"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
  echo "  PATH note:      add $bin_dir to PATH"
fi
