#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/gpt-oracle-web-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

if [[ -n "${ORACLE_TEST_PACKAGE_ROOT:-}" ]]; then
  cp -R "$ORACLE_TEST_PACKAGE_ROOT" "$test_root/package"
else
  command -v npm >/dev/null 2>&1 || oracle_web_die "npm is required unless ORACLE_TEST_PACKAGE_ROOT is set"
  (
    cd "$test_root"
    npm pack --silent "@steipete/oracle@$ORACLE_WEB_SUPPORTED_VERSION" >/dev/null
    tar -xzf "steipete-oracle-$ORACLE_WEB_SUPPORTED_VERSION.tgz"
  )
fi

export ORACLE_WEB_ORACLE_ROOT="$test_root/package"
export ORACLE_WEB_CODEX_HOME="$test_root/codex-home"
export ORACLE_WEB_BIN_DIR="$test_root/bin"
export ORACLE_WEB_STATE_DIR="$test_root/state"

"$script_dir/install.sh" --force
"$script_dir/verify.sh"
"$script_dir/install.sh"

node -e '
  const fs = require("node:fs");
  (async () => {
      const source = fs.readFileSync(process.argv[1], "utf8");
      const start = source.indexOf("async function attemptSendButton");
      const end = source.indexOf("async function clickTrustedPoint", start);
      if (start < 0 || end < 0) throw new Error("attemptSendButton source not found");
      const factory = new Function(
        "buildClickDispatcher",
        "buildAttachmentReadyExpression",
        "delay",
        "BrowserAutomationError",
        "clickTrustedPoint",
        "sendButtonTimeoutMs",
        "SEND_BUTTON_SELECTORS",
        `${source.slice(start, end)}; return attemptSendButton;`,
      );
      const attemptSendButton = factory(
        () => "",
        () => "attachment-ready",
        async () => {},
        class BrowserAutomationError extends Error {},
        async () => {},
        () => 300_000,
        [],
      );
      let evaluations = 0;
      const runtime = {
        evaluate: async () => ({
          result: { value: ++evaluations === 1 ? true : { status: "missing" } },
        }),
      };
      const clicked = await attemptSendButton(
        runtime,
        {},
        () => {},
        [{ name: "attachments-bundle.txt", generatedBundle: true }],
        300_000,
      );
      if (clicked !== false || evaluations !== 2) {
        throw new Error("attachment-ready missing button did not reach the Enter fallback");
      }
    })()
    .catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/promptComposer.js"

node -e '
  const fs = require("node:fs");
  (async () => {
      const source = fs.readFileSync(process.argv[1], "utf8");
      const enterStart = source.indexOf("async function submitViaEnter");
      const enterEnd = source.indexOf("export async function clearPromptComposer", enterStart);
      const clickStart = source.indexOf("async function clickTrustedPoint");
      const clickEnd = source.indexOf("async function waitForSubmissionStart", clickStart);
      if ([enterStart, enterEnd, clickStart, clickEnd].some((index) => index < 0)) {
        throw new Error("Enter fallback source not found");
      }
      const factory = new Function(
        "INPUT_SELECTORS",
        "ENTER_KEY_EVENT",
        "ENTER_KEY_TEXT",
        `${source.slice(enterStart, enterEnd)}; ${source.slice(clickStart, clickEnd)}; return submitViaEnter;`,
      );
      const submitViaEnter = factory(
        ["#prompt-textarea", "textarea"],
        { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 },
        "\\r",
      );
      const events = [];
      const runtime = {
        evaluate: async ({ expression }) => {
          if (!expression.includes("isEditable") || !expression.includes("querySelectorAll")) {
            throw new Error("Enter fallback did not re-locate an editable composer");
          }
          events.push("focus");
          return { result: { value: { x: 10, y: 20 } } };
        },
      };
      const input = {
        dispatchMouseEvent: async ({ type }) => events.push(type),
        dispatchKeyEvent: async ({ type }) => events.push(type),
      };
      await submitViaEnter(runtime, input);
      if (events.join(",") !== "focus,mousePressed,mouseReleased,keyDown,keyUp") {
        throw new Error(`Enter fallback did not focus and click the editor before submit: ${events.join(",")}`);
      }
    })()
    .catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/promptComposer.js"

profile_source="$test_root/profile-source"
profile_dest="$test_root/profile-dest"
mkdir -p "$profile_source/Default/Network" "$test_root/fake-path"
printf '%s\n' '{"profile":{"last_used":"Default"}}' > "$profile_source/Local State"
printf '%s\n' '{"profile":{"exit_type":"Crashed","exited_cleanly":false}}' > "$profile_source/Default/Preferences"
printf '%s\n' 'test-cookie-database-placeholder' > "$profile_source/Default/Network/Cookies"
real_rsync="$(command -v rsync)"
cat > "$test_root/fake-path/rsync" <<SCRIPT
#!/usr/bin/env bash
"$real_rsync" "\$@"
exit 23
SCRIPT
chmod 0755 "$test_root/fake-path/rsync"

PATH="$test_root/fake-path:$PATH" node -e '
  const { pathToFileURL } = require("node:url");
  import(pathToFileURL(process.argv[1]).href)
    .then((module) => module.copyChromeProfile(process.argv[2], process.argv[3], "Default"))
    .catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/profileCopy.js" "$profile_source" "$profile_dest"
[[ -f "$profile_dest/Default/Network/Cookies" ]] || oracle_web_die "guarded rsync exit 23 lost the cookie database"
grep -q '"exit_type":"Normal"' "$profile_dest/Default/Preferences" || \
  oracle_web_die "copied Profile was not marked as a clean exit"

profile_without_cookie="$test_root/profile-without-cookie"
mkdir -p "$profile_without_cookie/Default"
printf '%s\n' '{"profile":{"last_used":"Default"}}' > "$profile_without_cookie/Local State"
printf '%s\n' '{}' > "$profile_without_cookie/Default/Preferences"
if PATH="$test_root/fake-path:$PATH" node -e '
  const { pathToFileURL } = require("node:url");
  import(pathToFileURL(process.argv[1]).href)
    .then((module) => module.copyChromeProfile(process.argv[2], process.argv[3], "Default"))
    .catch(() => process.exit(1));
' "$test_root/package/dist/src/browser/profileCopy.js" "$profile_without_cookie" "$test_root/profile-dest-no-cookie"; then
  oracle_web_die "rsync exit 23 was accepted without copied session material"
fi

fake_oracle="$test_root/fake-oracle"
cat > "$fake_oracle" <<'SCRIPT'
#!/usr/bin/env bash
printf 'ORACLE_HOME_DIR=%s\n' "$ORACLE_HOME_DIR"
printf 'ARG=%s\n' "$@"
SCRIPT
chmod 0755 "$fake_oracle"

wrapper_output="$(
  ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_SESSION_DIR="$test_root/sessions" \
  ORACLE_WEB_CHROME_USER_DATA_DIR="$test_root/chrome" \
  ORACLE_WEB_CHROME_PROFILE="Profile 2" \
  "$test_root/bin/oracle-web" --browser-thinking-time max -p probe
)"

grep -q "ORACLE_HOME_DIR=$test_root/sessions" <<< "$wrapper_output"
grep -q '^ARG=--engine$' <<< "$wrapper_output"
grep -q '^ARG=browser$' <<< "$wrapper_output"
grep -q '^ARG=--browser-model-strategy$' <<< "$wrapper_output"
grep -q '^ARG=current$' <<< "$wrapper_output"
grep -q '^ARG=Profile 2$' <<< "$wrapper_output"
[[ "$(grep -c '^ARG=--browser-thinking-time$' <<< "$wrapper_output")" -eq 1 ]]
grep -q '^ARG=max$' <<< "$wrapper_output"
[[ "$(grep -c '^ARG=--browser-attachment-timeout$' <<< "$wrapper_output")" -eq 1 ]]
grep -q '^ARG=300s$' <<< "$wrapper_output"

default_wrapper_output="$(
  ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_SESSION_DIR="$test_root/default-sessions" \
  "$test_root/bin/oracle-web" -p probe
)"
[[ "$(grep -c '^ARG=--browser-thinking-time$' <<< "$default_wrapper_output")" -eq 1 ]]
grep -q '^ARG=extra-high$' <<< "$default_wrapper_output"
[[ "$(grep -c '^ARG=--browser-attachment-timeout$' <<< "$default_wrapper_output")" -eq 1 ]]
grep -q '^ARG=300s$' <<< "$default_wrapper_output"

override_wrapper_output="$(
  ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_SESSION_DIR="$test_root/override-sessions" \
  "$test_root/bin/oracle-web" --browser-attachment-timeout 90s -p probe
)"
[[ "$(grep -c '^ARG=--browser-attachment-timeout$' <<< "$override_wrapper_output")" -eq 1 ]]
grep -q '^ARG=90s$' <<< "$override_wrapper_output"

if grep -R -nE '/Users/[[:alnum:]_.-]+/' \
  "$ORACLE_WEB_REPO_ROOT/README.md" \
  "$ORACLE_WEB_REPO_ROOT/skill" \
  "$ORACLE_WEB_REPO_ROOT/bin" \
  "$ORACLE_WEB_REPO_ROOT/scripts" \
  "$ORACLE_WEB_REPO_ROOT/patches" \
  "$ORACLE_WEB_REPO_ROOT/NOTICE.md" \
  "$ORACLE_WEB_REPO_ROOT/.github" 2>/dev/null; then
  oracle_web_die "public files contain a personal absolute path"
fi

printf '%s\n' '# user modification after install' >> "$test_root/bin/oracle-web"
if "$script_dir/uninstall.sh" >"$test_root/uninstall-conflict.log" 2>&1; then
  oracle_web_die "uninstaller removed a modified managed file without --force"
fi
[[ "$(oracle_web_patch_state "$test_root/package")" == "patched" ]] || \
  oracle_web_die "uninstaller rolled back runtime before reporting a managed-file conflict"
"$script_dir/install.sh" --force

"$script_dir/uninstall.sh"
[[ "$(oracle_web_patch_state "$test_root/package")" == "pristine" ]] || \
  oracle_web_die "uninstall did not restore the pristine runtime"
[[ ! -e "$test_root/bin/oracle-web" ]] || oracle_web_die "uninstall left the wrapper behind"
[[ ! -e "$test_root/codex-home/skills/oracle-web/SKILL.md" ]] || \
  oracle_web_die "uninstall left managed Skill files behind"

mkdir -p "$test_root/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo user-owned wrapper' > "$test_root/bin/oracle-web"
chmod 0755 "$test_root/bin/oracle-web"
if "$script_dir/install.sh" >"$test_root/conflict.log" 2>&1; then
  oracle_web_die "installer overwrote a conflicting wrapper without --force"
fi
[[ "$(oracle_web_patch_state "$test_root/package")" == "pristine" ]] || \
  oracle_web_die "installer modified runtime before reporting a destination conflict"
rm -f "$test_root/bin/oracle-web"

printf '%s\n' '// unknown local drift' >> "$test_root/package/dist/src/browser/actions/attachments.js"
if "$script_dir/install.sh" --force >"$test_root/drift.log" 2>&1; then
  oracle_web_die "installer accepted an unknown Oracle runtime"
fi

echo "All offline tests passed"
