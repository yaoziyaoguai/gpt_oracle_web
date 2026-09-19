#!/usr/bin/env bash

readonly ORACLE_WEB_SUPPORTED_VERSION="0.17.3"
readonly ORACLE_WEB_COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ORACLE_WEB_REPO_ROOT="$(CDPATH= cd -- "$ORACLE_WEB_COMMON_DIR/../.." && pwd)"
readonly ORACLE_WEB_PATCH_FILE="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3.patch"
readonly ORACLE_WEB_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3.sha256"
readonly ORACLE_WEB_NPM_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-npm.sha256"
readonly ORACLE_WEB_A6D4E88_UPGRADE_PATCH="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-from-a6d4e88.patch"
readonly ORACLE_WEB_A6D4E88_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-a6d4e88.sha256"
readonly ORACLE_WEB_A6D4E88_NPM_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-a6d4e88-npm.sha256"
readonly ORACLE_WEB_F86C4FC_UPGRADE_PATCH="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-from-f86c4fc.patch"
readonly ORACLE_WEB_F86C4FC_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-f86c4fc.sha256"
readonly ORACLE_WEB_38F4BFF_UPGRADE_PATCH="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-from-38f4bff.patch"
readonly ORACLE_WEB_38F4BFF_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-38f4bff.sha256"
readonly ORACLE_WEB_042D57F_UPGRADE_PATCH="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-from-042d57f.patch"
readonly ORACLE_WEB_042D57F_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-042d57f.sha256"
readonly ORACLE_WEB_2FE5969_UPGRADE_PATCH="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-from-2fe5969.patch"
readonly ORACLE_WEB_2FE5969_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-2fe5969.sha256"
readonly ORACLE_WEB_209F3BA_UPGRADE_PATCH="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-from-209f3ba.patch"
readonly ORACLE_WEB_209F3BA_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-209f3ba.sha256"
readonly ORACLE_WEB_F0EA8D6_UPGRADE_PATCH="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-from-f0ea8d6.patch"
readonly ORACLE_WEB_F0EA8D6_HASH_MANIFEST="$ORACLE_WEB_REPO_ROOT/patches/oracle-0.17.3-f0ea8d6.sha256"

oracle_web_die() {
  echo "gpt-oracle-web: $*" >&2
  exit 1
}

oracle_web_hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

oracle_web_real_path() {
  local target="$1"
  local link
  while [[ -L "$target" ]]; do
    link="$(readlink "$target")"
    if [[ "$link" == /* ]]; then
      target="$link"
    else
      target="$(dirname "$target")/$link"
    fi
  done
  local directory
  directory="$(CDPATH= cd -- "$(dirname -- "$target")" && pwd -P)"
  printf '%s/%s\n' "$directory" "$(basename -- "$target")"
}

oracle_web_find_oracle_binary() {
  if [[ -n "${ORACLE_WEB_ORACLE_BIN:-}" ]]; then
    printf '%s\n' "$ORACLE_WEB_ORACLE_BIN"
    return
  fi
  command -v oracle || true
}

oracle_web_find_oracle_root() {
  if [[ -n "${ORACLE_WEB_ORACLE_ROOT:-}" ]]; then
    printf '%s\n' "$ORACLE_WEB_ORACLE_ROOT"
    return
  fi

  local oracle_bin
  oracle_bin="$(oracle_web_find_oracle_binary)"
  if [[ -n "$oracle_bin" && -e "$oracle_bin" ]]; then
    local resolved prefix candidate
    resolved="$(oracle_web_real_path "$oracle_bin")"
    prefix="$(CDPATH= cd -- "$(dirname -- "$resolved")/.." && pwd -P)"
    candidate="$prefix/libexec/lib/node_modules/@steipete/oracle"
    if [[ -f "$candidate/package.json" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_candidate
    brew_candidate="$(brew --prefix oracle 2>/dev/null || true)/libexec/lib/node_modules/@steipete/oracle"
    if [[ -f "$brew_candidate/package.json" ]]; then
      printf '%s\n' "$brew_candidate"
      return
    fi
  fi

  if command -v npm >/dev/null 2>&1; then
    local npm_candidate
    npm_candidate="$(npm root -g 2>/dev/null || true)/@steipete/oracle"
    if [[ -f "$npm_candidate/package.json" ]]; then
      printf '%s\n' "$npm_candidate"
      return
    fi
  fi

  return 1
}

oracle_web_package_version() {
  node -e 'const fs=require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version)' "$1/package.json"
}

oracle_web_validate_oracle_root() {
  local oracle_root="$1"
  [[ -f "$oracle_root/package.json" ]] || oracle_web_die "Oracle package root not found: $oracle_root"
  local version
  version="$(oracle_web_package_version "$oracle_root")"
  [[ "$version" == "$ORACLE_WEB_SUPPORTED_VERSION" ]] || \
    oracle_web_die "unsupported Oracle version $version; expected $ORACLE_WEB_SUPPORTED_VERSION"
}

oracle_web_patch_state() {
  local oracle_root="$1"
  local manifest="${2:-$ORACLE_WEB_HASH_MANIFEST}"
  local pristine patched relative actual
  local pristine_count=0
  local patched_count=0
  local total=0

  while read -r pristine patched relative; do
    [[ -z "${pristine:-}" || "$pristine" == \#* ]] && continue
    total=$((total + 1))
    [[ -f "$oracle_root/$relative" ]] || {
      printf '%s\n' "unknown"
      return
    }
    actual="$(oracle_web_hash_file "$oracle_root/$relative")"
    if [[ "$actual" == "$pristine" ]]; then
      pristine_count=$((pristine_count + 1))
    elif [[ "$actual" == "$patched" ]]; then
      patched_count=$((patched_count + 1))
    else
      printf '%s\n' "unknown"
      return
    fi
  done < "$manifest"

  if [[ "$total" -gt 0 && "$pristine_count" -eq "$total" ]]; then
    printf '%s\n' "pristine"
  elif [[ "$total" -gt 0 && "$patched_count" -eq "$total" ]]; then
    printf '%s\n' "patched"
  else
    printf '%s\n' "mixed"
  fi
}

oracle_web_current_manifest() {
  local oracle_root="$1"
  local manifest state
  for manifest in "$ORACLE_WEB_HASH_MANIFEST" "$ORACLE_WEB_NPM_HASH_MANIFEST"; do
    [[ -f "$manifest" ]] || continue
    state="$(oracle_web_patch_state "$oracle_root" "$manifest")"
    if [[ "$state" == "pristine" || "$state" == "patched" ]]; then
      printf '%s\n' "$manifest"
      return
    fi
  done
  printf '%s\n' "$ORACLE_WEB_HASH_MANIFEST"
}

oracle_web_default_codex_home() {
  printf '%s\n' "${ORACLE_WEB_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"
}

oracle_web_default_bin_dir() {
  printf '%s\n' "${ORACLE_WEB_BIN_DIR:-$HOME/.local/bin}"
}

oracle_web_default_state_dir() {
  printf '%s\n' "${ORACLE_WEB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gpt-oracle-web}"
}

oracle_web_assert_session_cleanup() {
  local session_root="$1"
  local slug="$2"
  local timeout_seconds="${3:-5}"
  [[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -le 60 ]] || \
    oracle_web_die "cleanup verification timeout must be an integer from 0 to 60 seconds"

  local meta_file="$session_root/sessions/$slug/meta.json"
  [[ -f "$meta_file" ]] || oracle_web_die "session metadata not found for cleanup verification: $slug"

  local fields chrome_pid user_data_dir
  fields="$(node -e '
    const fs = require("node:fs");
    const meta = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const runtime = meta?.browser?.runtime ?? {};
    const values = [
      Number.isInteger(runtime.chromePid) ? String(runtime.chromePid) : "",
      typeof runtime.userDataDir === "string" ? runtime.userDataDir : "",
    ];
    process.stdout.write(values.join("\t"));
  ' "$meta_file")" || oracle_web_die "could not read session metadata for cleanup verification: $slug"
  IFS=$'\t' read -r chrome_pid user_data_dir <<< "$fields"

  [[ "$chrome_pid" =~ ^[1-9][0-9]*$ ]] || oracle_web_die "session $slug has no valid recorded Chrome PID"
  [[ -n "$user_data_dir" ]] || oracle_web_die "session $slug has no recorded temporary Profile"

  local deadline=$((SECONDS + timeout_seconds))
  while ps -p "$chrome_pid" -o pid= >/dev/null 2>&1 || [[ -e "$user_data_dir" ]]; do
    if ((SECONDS >= deadline)); then
      break
    fi
    sleep 0.1
  done

  ! ps -p "$chrome_pid" -o pid= >/dev/null 2>&1 || \
    oracle_web_die "session $slug left recorded Chrome PID $chrome_pid alive"
  [[ ! -e "$user_data_dir" ]] || oracle_web_die "session $slug left its temporary Profile behind"
}
