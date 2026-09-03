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
  const source = fs.readFileSync(process.argv[1], "utf8");
  const launchReady = source.indexOf("const { chrome, reusedChrome } = acquiredChrome;");
  const firstRuntimeHint = source.indexOf("await emitRuntimeHint();", launchReady);
  const hookRegistration = source.indexOf("registerTerminationHooks(chrome", launchReady);
  const firstNavigation = source.indexOf("navigateToChatGPT(Page", launchReady);
  if (
    launchReady < 0 ||
    firstRuntimeHint < launchReady ||
    firstRuntimeHint > hookRegistration ||
    firstRuntimeHint > firstNavigation
  ) {
    throw new Error("owned runtime identity is not persisted before hooks/navigation");
  }
  const inputAwareCalls = source.match(/ensureThinkingTime\(Runtime, thinkingTime, logger, thinkingTargetModel, Input\)/g) ?? [];
  if (inputAwareCalls.length !== 2) {
    throw new Error(`local and remote thinking-time flows did not both receive CDP Input: ${inputAwareCalls.length}`);
  }
' "$test_root/package/dist/src/browser/index.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?picker-reload-test=${Date.now()}`);
    let reloaded = false;
    let evaluations = 0;
    const runtime = {
      evaluate: async ({ expression }) => {
        evaluations += 1;
        if (expression.includes("location.reload()")) {
          reloaded = true;
          return { result: { value: true } };
        }
        return {
          result: {
            value: reloaded
              ? { status: "already-selected", label: "Pro, item 5 of 5" }
              : { status: "chip-not-found" },
          },
        };
      },
    };
    const logger = () => {};
    logger.verbose = false;
    await module.ensureThinkingTime(runtime, "max", logger, null, {});
    if (!reloaded || evaluations !== 3) {
      throw new Error(`missing picker was not recovered by one bounded reload: reloaded=${reloaded}, evaluations=${evaluations}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/thinkingTime.js"

node -e '
  const fs = require("node:fs");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const start = source.indexOf("export async function navigateToChatGPT");
    const end = source.indexOf("async function dismissBlockingUi", start);
    if (start < 0 || end < 0) throw new Error("navigateToChatGPT source not found");
    const implementation = source.slice(start, end).replace("export async function", "async function");
    const factory = new Function(
      "waitForDocumentReady",
      `${implementation}; return navigateToChatGPT;`,
    );
    let waits = 0;
    const navigateToChatGPT = factory(async () => {
      waits += 1;
      if (waits === 1) throw new Error("Page did not reach ready state in time");
    });
    const calls = [];
    const page = {
      navigate: async ({ url }) => calls.push(`navigate:${url}`),
      reload: async () => calls.push("reload"),
    };
    await navigateToChatGPT(page, {}, "https://chatgpt.com/", () => {});
    if (waits !== 2 || calls.join(",") !== "navigate:https://chatgpt.com/,reload") {
      throw new Error(`navigation did not perform one bounded same-tab reload: waits=${waits}, calls=${calls.join(",")}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/navigation.js"

node -e '
  const fs = require("node:fs");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const start = source.indexOf("export async function submitPrompt");
    const end = source.indexOf("async function submitViaEnter", start);
    if (start < 0 || end < 0) throw new Error("submitPrompt source not found");
    const implementation = source.slice(start, end).replace("export async function", "async function");
    const factory = new Function(
      "waitForDomReady",
      "buildClickDispatcher",
      "INPUT_SELECTORS",
      "PROMPT_PRIMARY_SELECTOR",
      "PROMPT_FALLBACK_SELECTOR",
      "delay",
      "logDomFailure",
      "BrowserAutomationError",
      "attemptSendButton",
      "waitForSubmissionStart",
      "submitViaEnter",
      "verifyPromptCommitted",
      "clickTrustedPoint",
      `${implementation}; return submitPrompt;`,
    );
    const events = [];
    const submitPrompt = factory(
      async () => {},
      () => "",
      ["#prompt-textarea", "textarea"],
      "#prompt-textarea",
      "textarea[name=prompt-textarea]",
      async () => {},
      async () => {},
      class BrowserAutomationError extends Error {},
      async () => true,
      async () => true,
      async () => { events.push("enter"); },
      async () => true,
      async () => { events.push("trusted-click"); },
    );
    let evaluation = 0;
    const runtime = {
      evaluate: async () => {
        evaluation += 1;
        if (evaluation === 1) {
          return { result: { value: { focused: true, x: 20, y: 30 } } };
        }
        return {
          result: {
            value: {
              editorText: "probe",
              fallbackValue: "",
              activeValue: "probe",
            },
          },
        };
      },
    };
    const input = {
      insertText: async () => { events.push("insertText"); },
    };
    await submitPrompt({ runtime, input, baselineTurns: 0 }, "probe", () => {});
    if (events.join(",") !== "trusted-click,insertText") {
      throw new Error(`prompt insertion was not preceded by one trusted composer click: ${events.join(",")}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/promptComposer.js"

node -e '
  const fs = require("node:fs");
  const vm = require("node:vm");
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
  const vm = require("node:vm");
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
    let trustedClicks = 0;
    const attemptSendButton = factory(
      () => "",
      () => "attachment-ready",
      async () => {},
      class BrowserAutomationError extends Error {},
      async () => { trustedClicks += 1; },
      () => 300_000,
      ["button[data-testid=send-button]"],
    );
    class FakeElement {
      constructor() {
        this.disabled = true;
      }
      getBoundingClientRect() { return { left: 10, top: 20, width: 30, height: 40 }; }
      getAttribute(name) {
        if (name === "aria-disabled") return this.disabled ? "true" : "false";
        return null;
      }
      hasAttribute() { return false; }
      scrollIntoView() {}
    }
    const button = new FakeElement();
    let sendProbes = 0;
    const runtime = {
      evaluate: async ({ expression }) => {
        if (expression === "attachment-ready") {
          return { result: { value: true } };
        }
        sendProbes += 1;
        const value = vm.runInNewContext(expression, {
          document: { querySelectorAll: () => [button] },
          HTMLElement: FakeElement,
          window: {
            getComputedStyle: () => ({
              display: "block",
              visibility: "visible",
              pointerEvents: "auto",
            }),
          },
        });
        button.disabled = false;
        return { result: { value } };
      },
    };
    const clicked = await attemptSendButton(
      runtime,
      {},
      () => {},
      [{ name: "probe.txt", generatedBundle: false }],
      300_000,
    );
    if (!clicked || sendProbes !== 2 || trustedClicks !== 1) {
      throw new Error(`disabled attachment send button was not polled until enabled: clicked=${clicked}, probes=${sendProbes}, trustedClicks=${trustedClicks}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
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
        "PROMPT_PRIMARY_SELECTOR",
        "ENTER_KEY_EVENT",
        "ENTER_KEY_TEXT",
        `${source.slice(enterStart, enterEnd)}; ${source.slice(clickStart, clickEnd)}; return submitViaEnter;`,
      );
      const submitViaEnter = factory(
        ["#prompt-textarea", "textarea"],
        "#prompt-textarea",
        { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 },
        "\\r",
      );
      const events = [];
      let focused = null;
      class FakeTextarea {
        constructor(rect) {
          this.rect = rect;
          this.isContentEditable = false;
        }
        getBoundingClientRect() { return this.rect; }
        getAttribute() { return null; }
        focus() { focused = this; }
      }
      const decoy = new FakeTextarea({ left: 100, top: 10, width: 80, height: 40 });
      const primary = {
        isContentEditable: true,
        getBoundingClientRect: () => ({ left: 10, top: 10, width: 20, height: 40 }),
        getAttribute: (name) => name === "contenteditable" ? "true" : null,
        focus: () => { focused = primary; },
      };
      const document = {
        activeElement: decoy,
        querySelector: (selector) => selector === "#prompt-textarea" ? primary : null,
        querySelectorAll: (selector) => selector === "#prompt-textarea" ? [primary] : [decoy],
      };
      const runtime = {
        evaluate: async ({ expression }) => {
          if (
            !expression.includes("isEditable") ||
            !expression.includes("querySelectorAll") ||
            !expression.includes("document.activeElement") ||
            !expression.includes("querySelector(\"#prompt-textarea\")")
          ) {
            throw new Error("Enter fallback did not re-locate an editable composer");
          }
          events.push("focus");
          return {
            result: {
              value: vm.runInNewContext(expression, {
                document,
                HTMLTextAreaElement: FakeTextarea,
                HTMLInputElement: class {},
              }),
            },
          };
        },
      };
      const input = {
        dispatchMouseEvent: async ({ type, x }) => events.push(`${type}:${x}`),
        dispatchKeyEvent: async ({ type }) => events.push(type),
      };
      await submitViaEnter(runtime, input);
      if (focused !== primary || events.join(",") !== "focus,mousePressed:20,mouseReleased:20,keyDown,keyUp") {
        throw new Error(`Enter fallback did not focus and click the editor before submit: ${events.join(",")}`);
      }
    })()
    .catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/promptComposer.js"

node -e '
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const recoveryStart = source.indexOf("function createRecoveryCleanup");
    const recoveryEnd = source.indexOf("async function readPromptPreviewTurnIndex", recoveryStart);
    const attachedStart = source.indexOf("function createAttachedRuntimeCleanup");
    const attachedEnd = source.indexOf("async function refreshAttachRuntime", attachedStart);
    if ([recoveryStart, recoveryEnd, attachedStart, attachedEnd].some((index) => index < 0)) {
      throw new Error("recovery cleanup seam is missing");
    }
    const createRecoveryCleanup = new Function(
      "cleanupStaleProfileState",
      "rm",
      `${source.slice(recoveryStart, recoveryEnd)}; return createRecoveryCleanup;`,
    )(
      async () => {},
      async (target) => fs.promises.rm(target, { recursive: true, force: true }),
    );
    const createAttachedRuntimeCleanup = new Function(
      "path",
      "os",
      "rm",
      "delay",
      `${source.slice(attachedStart, attachedEnd)}; return createAttachedRuntimeCleanup;`,
    )(
      path,
      os,
      async (target) => fs.promises.rm(target, { recursive: true, force: true }),
      async () => {},
    );
    const profileDir = process.argv[2];
    fs.mkdirSync(profileDir, { recursive: true });
    fs.writeFileSync(`${profileDir}/marker`, "temporary profile");
    const calls = [];
    const cleanup = createRecoveryCleanup({
      client: { close: async () => calls.push("client.close") },
      chrome: { kill: async () => calls.push("chrome.kill") },
      userDataDir: profileDir,
      manualLogin: false,
      keepBrowser: false,
      logger: () => {},
      removeTerminationHooks: () => calls.push("hooks.remove"),
    });
    await cleanup();
    await cleanup();
    if (fs.existsSync(profileDir)) {
      throw new Error("temporary recovery profile survived cleanup");
    }
    if (calls.join(",") !== "hooks.remove,client.close,chrome.kill") {
      throw new Error(`recovery cleanup was not idempotent: ${calls.join(",")}`);
    }

    const attachedProfileDir = process.argv[3];
    fs.mkdirSync(attachedProfileDir, { recursive: true });
    fs.writeFileSync(`${attachedProfileDir}/marker`, "owned temporary profile");
    const attachedCalls = [];
    const attachedCleanup = createAttachedRuntimeCleanup({
      client: { Browser: { close: async () => attachedCalls.push("Browser.close") } },
      runtime: { userDataDir: attachedProfileDir, chromePid: 12345 },
      config: { copyProfileSource: "/signed-in-profile", keepBrowser: false },
      logger: () => {},
      killProcess: async () => attachedCalls.push("killProcess"),
    });
    await attachedCleanup();
    await attachedCleanup();
    if (fs.existsSync(attachedProfileDir)) {
      throw new Error("attached temporary profile survived cleanup");
    }
    if (attachedCalls.join(",") !== "Browser.close") {
      throw new Error(`attached runtime cleanup was not exact or idempotent: ${attachedCalls.join(",")}`);
    }

    const fallbackProfileDir = process.argv[5];
    fs.mkdirSync(fallbackProfileDir, { recursive: true });
    const fallbackCalls = [];
    const fallbackCleanup = createAttachedRuntimeCleanup({
      client: { Browser: { close: async () => { throw new Error("CDP closed"); } } },
      runtime: { userDataDir: fallbackProfileDir, chromePid: 12345, controllerPid: 99999 },
      config: { copyProfileSource: "/signed-in-profile", keepBrowser: false },
      logger: () => {},
      isProcessAlive: () => true,
      killProcess: async (pid) => fallbackCalls.push(`kill:${pid}`),
    });
    await fallbackCleanup();
    if (fallbackCalls.join(",") !== "kill:12345") {
      throw new Error(`fallback cleanup targeted something other than the recorded Chrome PID: ${fallbackCalls.join(",")}`);
    }

    const foreignProfileDir = process.argv[4];
    fs.mkdirSync(foreignProfileDir, { recursive: true });
    const foreignCalls = [];
    const foreignCleanup = createAttachedRuntimeCleanup({
      client: { Browser: { close: async () => foreignCalls.push("Browser.close") } },
      runtime: { userDataDir: foreignProfileDir, chromePid: 54321 },
      config: { copyProfileSource: "/signed-in-profile", keepBrowser: false },
      logger: () => {},
      killProcess: async () => foreignCalls.push("killProcess"),
    });
    await foreignCleanup();
    if (!fs.existsSync(foreignProfileDir) || foreignCalls.length !== 0) {
      throw new Error("attached cleanup touched a profile it did not own");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/reattach.js" \
  "$test_root/recovery-profile" \
  "$test_root/oracle-browser-owned" \
  "$test_root/normal-profile" \
  "$test_root/oracle-reattach-fallback"

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
[[ "$(grep -c '^ARG=--retain-hours$' <<< "$wrapper_output")" -eq 1 ]]
grep -q '^ARG=24$' <<< "$wrapper_output"

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

retention_override_output="$(
  ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_SESSION_DIR="$test_root/retention-override-sessions" \
  "$test_root/bin/oracle-web" --retain-hours 72 -p probe
)"
[[ "$(grep -c '^ARG=--retain-hours$' <<< "$retention_override_output")" -eq 1 ]]
grep -q '^ARG=72$' <<< "$retention_override_output"

for forbidden_arg in \
  --browser-keep-browser \
  --browser-tab=current \
  --browser-attach-running \
  --followup=old-session \
  --browser-follow-up=next
do
  if ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
    ORACLE_WEB_SESSION_DIR="$test_root/forbidden-sessions" \
    "$test_root/bin/oracle-web" "$forbidden_arg" -p probe \
    >"$test_root/forbidden.log" 2>&1; then
    oracle_web_die "wrapper accepted state-reusing option $forbidden_arg"
  fi
done

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

broad_kill_pattern='\b(p''kill|kill''all)\b'
if rg -n "$broad_kill_pattern" \
  "$ORACLE_WEB_REPO_ROOT/bin" \
  "$ORACLE_WEB_REPO_ROOT/scripts" \
  "$ORACLE_WEB_REPO_ROOT/skill" \
  "$ORACLE_WEB_REPO_ROOT/patches"; then
  oracle_web_die "broad process-kill command found; cleanup must use the exact recorded Chrome identity"
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
