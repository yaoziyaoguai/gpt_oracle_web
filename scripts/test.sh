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
    cd package
    npm install --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null
  )
fi

export ORACLE_WEB_ORACLE_ROOT="$test_root/package"
export ORACLE_WEB_CODEX_HOME="$test_root/codex-home"
export ORACLE_WEB_CLAUDE_HOME="$test_root/claude-home"
export ORACLE_WEB_BIN_DIR="$test_root/bin"
export ORACLE_WEB_STATE_DIR="$test_root/state"
export XDG_CONFIG_HOME="$test_root/config"

"$script_dir/install.sh" --force
"$script_dir/verify.sh"
"$script_dir/install.sh"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_DA31C46_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_DA31C46_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "da31c46 runtime unexpectedly matched the current manifest"
if [[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_DA31C46_HASH_MANIFEST")" != "patched" && \
      "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_DA31C46_NPM_HASH_MANIFEST")" != "patched" ]]; then
  oracle_web_die "legacy runtime did not match either da31c46 manifest"
fi
"$script_dir/install.sh"
"$script_dir/verify.sh"

node "$script_dir/test-cli.mjs" "$test_root/package" "$test_root/bin/oracle-web"
node "$script_dir/test-browser-source.mjs" "$test_root/bin/oracle-web"
node "$script_dir/test-attachments.mjs" "$test_root/package"
node "$script_dir/test-composer-dom.mjs" "$test_root/package"
node "$script_dir/test-answer-wait.mjs" "$test_root/package"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_E13EA4C_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_E13EA4C_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "e13ea4c runtime unexpectedly matched the current manifest"
if [[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_E13EA4C_HASH_MANIFEST")" != "patched" && \
      "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_E13EA4C_NPM_HASH_MANIFEST")" != "patched" ]]; then
  oracle_web_die "legacy runtime did not match either e13ea4c manifest"
fi
"$script_dir/install.sh"
"$script_dir/verify.sh"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const policies = await import(`${pathToFileURL(process.argv[1]).href}?copied-profile-cookie-sync=${Date.now()}`);
    const shouldSync = policies.shouldSyncBrowserCookies(
      { cookieSync: true },
      { manualLogin: false, profileIsPreSigned: true, usingCopiedProfile: true },
    );
    if (shouldSync) {
      throw new Error("copied-profile runs unexpectedly require source-profile cookie decryption");
    }

    const lifecycle = await import(`${pathToFileURL(process.argv[2]).href}?browser-language=${Date.now()}`);
    const flags = lifecycle.buildChromeFlagsForTest(false, undefined, false);
    if (flags.some((flag) => flag.startsWith("--lang=") || flag.startsWith("--accept-lang="))) {
      throw new Error("Oracle Chrome still forces an English browser language");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/policies.js" \
  "$test_root/package/dist/src/browser/chromeLifecycle.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?login-probe-evidence-test=${Date.now()}`);
    const runtime = {
      evaluate: async ({ expression }) => {
        if (expression.includes("/api/auth/session")) {
          return { result: { value: {
            ok: false, status: 401, sessionAuthenticated: false, sessionResolved: false,
            domLoginCta: false, onAuthPage: false, appAuthenticated: false, cfBlocked: false,
            pageUrl: "https://chatgpt.com/", error: null,
          } } };
        }
        throw new Error("cdp unavailable");
      },
    };
    let failure = null;
    try {
      await module.ensureLoggedIn(runtime, () => {}, { appliedCookies: 0, preSignedProfile: true });
    } catch (error) {
      failure = error;
    }
    if (!failure) {
      throw new Error("an unverified copied-profile login did not fail closed");
    }
    const message = String(failure.message);
    if (
      !/probe: sessionStatus=401/.test(message) ||
      !/appliedCookies=0/.test(message) ||
      !/preSignedProfile=true/.test(message)
    ) {
      throw new Error(`login failure did not carry probe evidence for post-mortem: ${message}`);
    }
    if (!message.includes("copied Chrome profile did not yield a verifiable ChatGPT login")) {
      throw new Error("copied-profile login failure retained the misleading cookie-sync hint");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/navigation.js"

node -e '
  const fs = require("node:fs");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const start = source.indexOf("async function waitForLogin");
    const end = source.indexOf("async function maybeRecoverLongAssistantResponse", start);
    if (start < 0 || end < 0) throw new Error("waitForLogin source not found");
    const calls = [];
    const waitForLogin = new Function(
      "ensureLoggedIn",
      "resolveManualLoginWaitMs",
      "formatManualLoginSetupCommand",
      "defaultManualLoginProfileDir",
      `${source.slice(start, end)}; return waitForLogin;`,
    )(
      async (runtime, logger, options) => { calls.push(options); },
      () => 0,
      () => "setup",
      () => "/default",
    );
    await waitForLogin({
      runtime: {}, logger: () => {}, appliedCookies: 3, manualLogin: false,
      timeoutMs: 1000, profileDir: "/p", keepBrowser: false, preSignedProfile: true,
    });
    await waitForLogin({
      runtime: {}, logger: () => {}, appliedCookies: 3, manualLogin: false,
      timeoutMs: 1000, profileDir: "/p", keepBrowser: false,
    });
    if (calls.length !== 2) {
      throw new Error(`waitForLogin did not reach ensureLoggedIn twice: ${calls.length}`);
    }
    if (calls[0].preSignedProfile !== true || calls[1].preSignedProfile !== undefined) {
      throw new Error(`waitForLogin did not forward preSignedProfile to ensureLoggedIn: ${JSON.stringify(calls)}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/index.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?fresh-conversation-guard=${Date.now()}`);
    const makeRuntime = (pathname) => ({
      evaluate: async ({ expression }) => {
        if (expression.includes("location.href")) {
          return { result: { value: pathname === "/" ? "https://chatgpt.com/" : `https://chatgpt.com${pathname}` } };
        }
        return { result: { value: true } };
      },
    });
    let threw = null;
    try {
      await module.ensurePromptReady(
        makeRuntime("/c/6aaa63dc-58c4-83eb-9422-58a90bc556dd"), 1000, () => {},
        { requireFreshConversation: true },
      );
    } catch (error) { threw = error; }
    if (!threw || !/existing conversation/.test(threw.message)) {
      throw new Error("a restored existing conversation was not refused before first submission");
    }
    await module.ensurePromptReady(makeRuntime("/"), 1000, () => {}, { requireFreshConversation: true });
    await module.ensurePromptReady(makeRuntime("/c/own-run-conversation"), 1000, () => {});
    console.log("fresh-conversation guard ok");
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/navigation.js"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_A6D4E88_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_A6D4E88_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "a6d4e88 runtime unexpectedly matched the current manifest"
if [[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_A6D4E88_HASH_MANIFEST")" != "patched" && \
      "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_A6D4E88_NPM_HASH_MANIFEST")" != "patched" ]]; then
  oracle_web_die "legacy runtime did not match either a6d4e88 manifest"
fi
"$script_dir/install.sh"
"$script_dir/verify.sh"

if [[ "$(oracle_web_current_manifest "$test_root/package")" == "$ORACLE_WEB_NPM_HASH_MANIFEST" ]]; then
  "$script_dir/uninstall.sh"
  node -e '
    const fs = require("node:fs");
    const path = process.argv[1];
    const source = fs.readFileSync(path, "utf8");
    const anchor = `        "--disable-hang-monitor",\n`;
    if (source.split(anchor).length !== 2) {
      throw new Error("npm fixture Chrome flag anchor was not unique");
    }
    fs.writeFileSync(path, source.replace(anchor, `${anchor}        "--hide-crash-restore-bubble",\n`));
  ' "$test_root/package/dist/src/browser/chromeLifecycle.js"
  [[ "$(oracle_web_patch_state "$test_root/package")" == "pristine" ]] || \
    oracle_web_die "npm fixture normalization did not reach the Homebrew pristine manifest"
  "$script_dir/install.sh"
  "$script_dir/verify.sh"
fi

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_F86C4FC_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_F86C4FC_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "f86c4fc runtime unexpectedly matched the current manifest"
[[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_F86C4FC_HASH_MANIFEST")" == "patched" ]] || \
  oracle_web_die "legacy runtime did not match the f86c4fc manifest"
"$script_dir/install.sh"
"$script_dir/verify.sh"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_38F4BFF_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_38F4BFF_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "38f4bff runtime unexpectedly matched the current manifest"
[[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_38F4BFF_HASH_MANIFEST")" == "patched" ]] || \
  oracle_web_die "legacy runtime did not match the 38f4bff manifest"
"$script_dir/install.sh"
"$script_dir/verify.sh"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_042D57F_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_042D57F_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "042d57f runtime unexpectedly matched the current manifest"
[[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_042D57F_HASH_MANIFEST")" == "patched" ]] || \
  oracle_web_die "legacy runtime did not match the 042d57f manifest"
"$script_dir/install.sh"
"$script_dir/verify.sh"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_2FE5969_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_2FE5969_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "2fe5969 runtime unexpectedly matched the current manifest"
[[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_2FE5969_HASH_MANIFEST")" == "patched" ]] || \
  oracle_web_die "legacy runtime did not match the 2fe5969 manifest"
"$script_dir/install.sh"
"$script_dir/verify.sh"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_209F3BA_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_209F3BA_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "209f3ba runtime unexpectedly matched the current manifest"
[[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_209F3BA_HASH_MANIFEST")" == "patched" ]] || \
  oracle_web_die "legacy runtime did not match the 209f3ba manifest"
"$script_dir/install.sh"
"$script_dir/verify.sh"

patch -C -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_F0EA8D6_UPGRADE_PATCH" >/dev/null
patch -f -R -p1 -d "$test_root/package" -i "$ORACLE_WEB_F0EA8D6_UPGRADE_PATCH" >/dev/null
[[ "$(oracle_web_patch_state "$test_root/package")" == "unknown" ]] || \
  oracle_web_die "legacy runtime unexpectedly matched the current manifest"
[[ "$(oracle_web_patch_state "$test_root/package" "$ORACLE_WEB_F0EA8D6_HASH_MANIFEST")" == "patched" ]] || \
  oracle_web_die "legacy runtime did not match the f0ea8d6 manifest"
"$script_dir/install.sh"
"$script_dir/verify.sh"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?terminal-fallback-test=${Date.now()}`);
    let state = module.createTerminalGateState(0);
    let decision = module.classifyTurnTerminal(state, {
      now: 0,
      len: 120,
      contentKey: "message-1::complete answer",
      stopVisible: false,
      barVisible: false,
      strongThinkingActive: false,
    }, { barConfirmCycles: 3, minStableMs: 1_200, quietStableMs: 8_000 });
    state = decision.state;
    decision = module.classifyTurnTerminal(state, {
      now: 8_100,
      len: 120,
      contentKey: "message-1::complete answer",
      stopVisible: false,
      barVisible: false,
      strongThinkingActive: false,
    }, { barConfirmCycles: 3, minStableMs: 1_200, quietStableMs: 8_000 });
    if (decision.terminal) {
      throw new Error("a quiet candidate without completion evidence became terminal");
    }
    decision = module.classifyTurnTerminal(decision.state, {
      now: 16_500,
      len: 140,
      contentKey: "message-1::answer still changing",
      stopVisible: false,
      barVisible: false,
      strongThinkingActive: false,
    }, { barConfirmCycles: 3, minStableMs: 1_200, quietStableMs: 8_000 });
    if (decision.terminal) {
      throw new Error("content changes bypassed the terminal gate");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/assistantResponse.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?run-deadline-test=${Date.now()}`);
    const deadline = module.createBrowserRunDeadlineForTest(25);
    let failure = null;
    try {
      await deadline.promise;
    } catch (error) {
      failure = error;
    } finally {
      deadline.dispose();
    }
    if (!failure || failure.message !== "browser-run-deadline-exceeded" || deadline.expired !== true) {
      throw new Error("browser run did not expose one shared hard deadline");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/index.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const sessionManager = await import(`${pathToFileURL(process.argv[1]).href}?slug-test=${Date.now()}`);
    const requested = "first-agent-core-next-slice-20260907-a";
    const resolved = sessionManager.createSessionId("unused", requested);
    if (resolved !== requested) {
      throw new Error(`custom slug was silently changed: ${requested} -> ${resolved}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/sessionManager.js"

grep -q '3–12 word slug' "$test_root/package/dist/src/cli/help.js" || \
  oracle_web_die "CLI help still documents the truncating custom-slug limit"
grep -q '3–12 words' "$test_root/package/dist/src/cli/tui/index.js" || \
  oracle_web_die "TUI still documents the truncating custom-slug limit"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const thinking = await import(`${pathToFileURL(process.argv[1]).href}?thinking-evidence-test=${Date.now()}`);
    const index = await import(`${pathToFileURL(process.argv[2]).href}?thinking-model-evidence-test=${Date.now()}`);
    const evidence = await thinking.ensureThinkingTime({
      evaluate: async ({ expression }) => ({ result: { value: expression.includes("positionPattern") ? false : {
        status: "already-selected",
        label: "Pro，第 5 项，共 5 项",
      } } }),
    }, "max", () => {}, null, {});
    if (!evidence?.verified || evidence.resolvedLabel !== "Pro，第 5 项，共 5 项") {
      throw new Error("visible five-position selection was not returned as structured evidence");
    }
    const modelEvidence = index.buildPowerControlModelSelectionEvidenceForTest(
      "GPT-5.6 Sol",
      "current",
      evidence,
    );
    if (!modelEvidence.verified || modelEvidence.resolvedLabel !== evidence.resolvedLabel) {
      throw new Error("visible five-position selection was not promoted into modelSelection metadata");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/thinkingTime.js" \
  "$test_root/package/dist/src/browser/index.js"

node --input-type=module - "$test_root/package/dist/src/browser/actions/thinkingTime.js" <<'NODE'
import { pathToFileURL } from "node:url";

const thinking = await import(`${pathToFileURL(process.argv[2]).href}?thinking-control-drift=${Date.now()}`);
class FakeEvent extends Event {}
class FakeButton extends EventTarget {
  constructor(kind, text) {
    super();
    this.kind = kind;
    this.textContent = text;
    this.tabIndex = 0;
    this.parentElement = null;
  }
  getAttribute(name) {
    const attrs = {
      "aria-label": this.kind === "current" ? "选择 ChatGPT 模型" : null,
      "aria-haspopup": "menu",
      "aria-expanded": "false",
      "data-testid": this.kind === "legacy" ? "model-switcher-dropdown-button" : null,
      "aria-hidden": null,
    };
    return attrs[name] ?? null;
  }
  getBoundingClientRect() {
    return { left: 100, right: 260, top: 80, bottom: 116, width: 160, height: 36 };
  }
  contains(node) { return node === this; }
  matches(selector) {
    return this.kind === "legacy" && selector.includes("model-switcher-dropdown-button");
  }
  closest() { return null; }
}

async function probe(kind, text) {
  const button = new FakeButton(kind, text);
  let clock = 0;
  const document = {
    activeElement: null,
    body: {},
    querySelector(selector) {
      return kind === "legacy" && selector.includes("model-switcher-dropdown-button")
        ? button
        : null;
    },
    querySelectorAll(selector) {
      return kind === "current" && selector === 'form button[aria-haspopup="menu"][aria-label]'
        ? [button]
        : [];
    },
    elementFromPoint() { return button; },
    dispatchEvent() { return true; },
    getElementById() { return null; },
  };
  const window = {
    innerWidth: 1280,
    innerHeight: 720,
    visualViewport: { width: 1280, height: 720, offsetLeft: 0, offsetTop: 0 },
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1", pointerEvents: "auto",
    }),
  };
  const run = new Function(
    "document", "window", "HTMLElement", "EventTarget", "MouseEvent", "KeyboardEvent",
    "performance", "setTimeout",
    `return ${thinking.buildThinkingTimeExpressionForTest("max")};`,
  );
  const result = await run(
    document,
    window,
    FakeButton,
    EventTarget,
    FakeEvent,
    FakeEvent,
    { now: () => (clock += 1000) },
    (callback) => { callback(); return 1; },
  );
  if (result?.status !== "slider-click-required" || result?.purpose !== "open-effort-picker") {
    throw new Error(`${kind} thinking control was not located: ${JSON.stringify(result)}`);
  }
}

async function probeCombinedPicker() {
  class FakeNode extends EventTarget {
    constructor(attrs = {}, text = "") {
      super();
      this.attrs = attrs;
      this.textContent = text;
      this.tabIndex = attrs.tabindex ?? -1;
      this.parentElement = null;
      this.children = [];
    }
    getAttribute(name) { return this.attrs[name] ?? null; }
    getBoundingClientRect() {
      return { left: 100, right: 346, top: 80, bottom: 116, width: 246, height: 36 };
    }
    contains(node) { return node === this || this.children.includes(node); }
    matches() { return false; }
    closest() { return null; }
    querySelector(selector) {
      if (selector === '[data-testid="composer-model-picker-slider-simple-view"]') {
        return this.children.find(
          (node) => node.attrs["data-testid"] === "composer-model-picker-slider-simple-view",
        ) ?? null;
      }
      if (selector.includes('[role="slider"]')) {
        return this.children.find((node) => node.attrs.role === "slider")
          ?? this.children.find((node) => node.attrs.role === "menuitem")
          ?? null;
      }
      return null;
    }
    querySelectorAll(selector) {
      return selector.includes('[role="slider"]') || selector.includes('[role="menuitem"]')
        ? this.children
        : [];
    }
  }

  const control = new FakeNode({ role: "menuitem", "aria-label": "强度", "aria-valuenow": "0", "aria-valuemin": "0", "aria-valuemax": "4" });
  const view = new FakeNode(
    { "data-testid": "composer-model-picker-slider-simple-view" },
    "中即时，第 1 项，共 5 项。使用左右方向键调整强度",
  );
  const menu = new FakeNode(
    { role: "menu", "data-state": "open" },
    "中即时，第 1 项，共 5 项。最新GPT-5.6 Sol",
  );
  const button = new FakeNode({
    "aria-label": "选择 ChatGPT 模型",
    "aria-haspopup": "menu",
    "aria-expanded": "true",
    "aria-controls": "combined-menu",
  }, "思考强度");
  view.children = [control];
  menu.children = [view, control];
  view.parentElement = menu;
  control.parentElement = menu;

  let clock = 0;
  const document = {
    activeElement: control,
    body: {},
    querySelector(selector) {
      return selector === '[data-testid="composer-model-picker-slider-simple-view"]'
        ? view
        : null;
    },
    querySelectorAll(selector) {
      if (selector === 'form button[aria-haspopup="menu"][aria-label]') return [button];
      if (selector.includes('[role="menu"]') || selector.includes("[data-radix-collection-root]")) {
        return [menu];
      }
      return [];
    },
    getElementById(id) { return id === "combined-menu" ? menu : null; },
    elementFromPoint() { return control; },
    dispatchEvent() { return true; },
  };
  const window = {
    innerWidth: 1280,
    innerHeight: 720,
    visualViewport: { width: 1280, height: 720, offsetLeft: 0, offsetTop: 0 },
    getComputedStyle: () => ({
      display: "flex", visibility: "visible", opacity: "1", pointerEvents: "auto",
    }),
  };
  const run = new Function(
    "document", "window", "HTMLElement", "EventTarget", "MouseEvent", "KeyboardEvent",
    "performance", "setTimeout",
    `return ${thinking.buildThinkingTimeExpressionForTest("max")};`,
  );
  const result = await run(
    document,
    window,
    FakeNode,
    EventTarget,
    FakeEvent,
    FakeEvent,
    { now: () => (clock += 1000) },
    (callback) => { callback(); return 1; },
  );
  if (result?.status !== "slider-key-required" || result?.key !== "ArrowRight") {
    throw new Error(`combined picker did not reach its five-position slider: ${JSON.stringify(result)}`);
  }

  const targetControl = new FakeNode({ role: "menuitem", "aria-label": "强度" });
  const targetThumb = new FakeNode({ role: "slider", "aria-valuenow": "4", "aria-valuemin": "0", "aria-valuemax": "4" });
  const targetView = new FakeNode(
    { "data-testid": "composer-model-picker-slider-simple-view" },
    "6Pro",
  );
  const targetMenu = new FakeNode(
    { role: "menu", "data-state": "open" },
    "6Pro更快消耗使用额度Pro，第 5 项，共 5 项。使用左右方向键调整强度已锁定，打开访问权限选项最新GPT-5.6 SolGPT-5.5",
  );
  const targetButton = new FakeNode({
    "aria-label": "选择 ChatGPT 模型",
    "aria-haspopup": "menu",
    "aria-expanded": "true",
    "aria-controls": "combined-menu-at-target",
  }, "思考强度");
  targetMenu.children = [targetView, targetControl, targetThumb];
  targetView.parentElement = targetMenu;
  targetControl.parentElement = targetMenu;
  targetThumb.parentElement = targetMenu;

  const targetDocument = {
    activeElement: targetThumb,
    body: {},
    querySelector(selector) {
      return selector === '[data-testid="composer-model-picker-slider-simple-view"]'
        ? targetView
        : null;
    },
    querySelectorAll(selector) {
      if (selector === 'form button[aria-haspopup="menu"][aria-label]') return [targetButton];
      if (selector.includes('[role="menu"]') || selector.includes("[data-radix-collection-root]")) {
        return [targetMenu];
      }
      return [];
    },
    getElementById(id) { return id === "combined-menu-at-target" ? targetMenu : null; },
    elementFromPoint() { return targetThumb; },
    dispatchEvent() { return true; },
  };
  const targetResult = await run(
    targetDocument,
    window,
    FakeNode,
    EventTarget,
    FakeEvent,
    FakeEvent,
    { now: () => (clock += 1000) },
    (callback) => { callback(); return 1; },
  );
  if (targetResult?.status !== "already-selected") {
    throw new Error(
      `combined picker did not verify its current slider value: ${JSON.stringify(targetResult)}`,
    );
  }

  const menuOnlyControl = new FakeNode({ role: "menuitem", "aria-label": "强度" });
  const menuOnlyMenu = new FakeNode(
    { role: "menu", "data-state": "open" },
    "6Pro更快消耗使用额度Pro，第 5 项，共 5 项。使用左右方向键调整强度已锁定，打开访问权限选项最新GPT-5.6 SolGPT-5.5",
  );
  const menuOnlyButton = new FakeNode({
    "aria-label": "选择 ChatGPT 模型",
    "aria-haspopup": "menu",
    "aria-expanded": "true",
    "aria-controls": "combined-menu-without-view",
  }, "思考强度");
  menuOnlyMenu.children = [menuOnlyControl];
  menuOnlyControl.parentElement = menuOnlyMenu;
  const menuOnlyDocument = {
    activeElement: menuOnlyMenu,
    body: {},
    querySelector() { return null; },
    querySelectorAll(selector) {
      if (selector === 'form button[aria-haspopup="menu"][aria-label]') return [menuOnlyButton];
      if (selector.includes('[role="menu"]') || selector.includes("[data-radix-collection-root]")) {
        return [menuOnlyMenu];
      }
      return [];
    },
    getElementById(id) { return id === "combined-menu-without-view" ? menuOnlyMenu : null; },
    elementFromPoint() { return menuOnlyControl; },
    dispatchEvent() { return true; },
  };
  const menuOnlyResult = await run(
    menuOnlyDocument,
    window,
    FakeNode,
    EventTarget,
    FakeEvent,
    FakeEvent,
    { now: () => (clock += 1000) },
    (callback) => { callback(); return 1; },
  );
  if (menuOnlyResult?.status === "already-selected" || menuOnlyResult?.status === "switched") {
    throw new Error(
      `combined picker trusted menu text without a current-position control: ${JSON.stringify(menuOnlyResult)}`,
    );
  }

  let delayedMenuScans = 0;
  const delayedDocument = {
    ...targetDocument,
    getElementById() { return null; },
    querySelectorAll(selector) {
      if (selector === 'form button[aria-haspopup="menu"][aria-label]') return [targetButton];
      if (selector.includes('[role="menu"]') || selector.includes("[data-radix-collection-root]")) {
        delayedMenuScans += 1;
        return delayedMenuScans > 1 ? [targetMenu] : [];
      }
      return [];
    },
  };
  const delayedResult = await run(
    delayedDocument,
    window,
    FakeNode,
    EventTarget,
    FakeEvent,
    FakeEvent,
    { now: () => (clock += 1000) },
    (callback) => { callback(); return 1; },
  );
  if (delayedResult?.status !== "already-selected") {
    throw new Error(
      `combined picker did not retry a late-mounted slider: ${JSON.stringify(delayedResult)}`,
    );
  }
}

await probe("legacy", "GPT-6 Astra");
await probe("current", "思考强度中");
await probe("current", "选择模型GPT-6 Astra中无极低轻度中高极高最高Ultra持续");
await probeCombinedPicker();
console.log("thinking control DOM drift fixtures ok");
NODE

node -e '
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  const { pathToFileURL } = require("node:url");
  (async () => {
    process.env.NODE_ENV = "test";
    const lifecycle = await import(`${pathToFileURL(process.argv[1]).href}?signal-cleanup-test=${Date.now()}`);
    const profile = fs.mkdtempSync(path.join(os.tmpdir(), "oracle-browser-signal-test-"));
    const events = [];
    const previousExitCode = process.exitCode;
    const removeHooks = lifecycle.registerTerminationHooks({
      kill: async () => events.push("kill"),
    }, profile, false, () => {}, {
      isInFlight: () => true,
      forceProfileCleanup: true,
      emitRuntimeHint: async (signal) => events.push(`persist:${signal}`),
    });
    process.emit("SIGINT", "SIGINT");
    await new Promise((resolve) => setTimeout(resolve, 75));
    removeHooks();
    process.exitCode = previousExitCode;
    if (events.join(",") !== "persist:SIGINT,kill" || fs.existsSync(profile)) {
      throw new Error(`SIGINT did not persist interruption before exact cleanup: ${events.join(",")}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/chromeLifecycle.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?runtime-hint-status-test=${Date.now()}`);
    const update = module.buildRuntimeHintSessionUpdateForTest(
      { timeoutMs: 2_700_000 },
      { chromePid: 1234, interruptedSignal: "SIGINT" },
      { verified: true, resolvedLabel: "Pro，第 5 项，共 5 项" },
      "2026-09-07T00:00:00.000Z",
    );
    if (update.status !== "error" || update.completedAt !== "2026-09-07T00:00:00.000Z") {
      throw new Error("interrupted runtime hint left session metadata running");
    }
    if (update.browser.modelSelection.verified !== true || update.response.incompleteReason !== "interrupted") {
      throw new Error("interruption update lost browser evidence or response state");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/cli/sessionRunner.js"

node -e '
  const fs = require("node:fs");
  const source = fs.readFileSync(process.argv[1], "utf8");
  const launchReady = source.indexOf("const { chrome, reusedChrome } = acquiredChrome;");
  const firstRuntimeHint = source.indexOf("await emitRuntimeHint();", launchReady);
  const hookRegistration = source.indexOf("registerTerminationHooks(chrome", launchReady);
  const firstNavigation = source.indexOf("navigateToChatGPT(Page", launchReady);
  const stableWindow = source.indexOf("await stabilizeChromeWindow(client, logger);", launchReady);
  const stableWindowCalls = source.match(/await (?:raceWithDisconnect\()?stabilizeChromeWindow\(client, logger\)/g) ?? [];
  if (
    launchReady < 0 ||
    firstRuntimeHint < launchReady ||
    firstRuntimeHint > hookRegistration ||
    firstRuntimeHint > firstNavigation ||
    stableWindow < launchReady ||
    stableWindow > firstNavigation ||
    stableWindowCalls.length !== 3
  ) {
    throw new Error("runtime identity/window bounds are not established before navigation");
  }
  const inputAwareCalls = source.match(/ensureThinkingTime\(Runtime, thinkingTime, logger, thinkingTargetModel, Input\)/g) ?? [];
  if (inputAwareCalls.length !== 2) {
    throw new Error(`local and remote thinking-time flows did not both receive CDP Input: ${inputAwareCalls.length}`);
  }
' "$test_root/package/dist/src/browser/index.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?disconnect-cleanup-test=${Date.now()}`);
    const terminate = module.terminateLocalChromeAfterRunForTest;
    if (typeof terminate !== "function") {
      throw new Error("local Chrome disconnect cleanup is not testable");
    }
    const calls = [];
    const chrome = { kill: async () => calls.push("kill") };
    if (!await terminate({
      connectionClosedUnexpectedly: true,
      usingCopiedProfile: true,
      terminatedRecordedChrome: false,
      chrome,
    }) || calls.length !== 1) {
      throw new Error("copy-profile Chrome would survive an unexpected CDP disconnect");
    }
    if (await terminate({
      connectionClosedUnexpectedly: true,
      usingCopiedProfile: false,
      terminatedRecordedChrome: false,
      chrome,
    }) || calls.length !== 1) {
      throw new Error("persistent Chrome would be terminated after a recoverable disconnect");
    }
    if (!await terminate({
      connectionClosedUnexpectedly: false,
      usingCopiedProfile: false,
      terminatedRecordedChrome: false,
      chrome,
    }) || calls.length !== 2) {
      throw new Error("normal local Chrome cleanup was disabled");
    }
    if (await terminate({
      connectionClosedUnexpectedly: false,
      usingCopiedProfile: true,
      terminatedRecordedChrome: true,
      chrome,
    }) || calls.length !== 2) {
      throw new Error("an already-terminated recorded Chrome was killed twice");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/index.js"

node -e '
  const fs = require("node:fs");
  const vm = require("node:vm");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const start = source.indexOf("async function stabilizeChromeWindow");
    const end = source.indexOf("async function enableFocusEmulation", start);
    if (start < 0 || end < 0) throw new Error("stable Chrome window helper is missing");
    const implementation = source.slice(start, end);
    const stabilizeChromeWindow = new Function(
      `${implementation}; return stabilizeChromeWindow;`,
    )();
    const calls = [];
    const client = {
      Browser: {
        getWindowForTarget: async () => ({ windowId: 7 }),
        setWindowBounds: async ({ bounds }) => calls.push(bounds),
        getWindowBounds: async () => ({
          bounds: { width: 1280, height: 720, windowState: "normal" },
        }),
      },
    };
    await stabilizeChromeWindow(client, () => {});
    if (
      calls.length !== 2 ||
      calls[0].windowState !== "normal" ||
      calls[1].width !== 1280 ||
      calls[1].height !== 720
    ) {
      throw new Error(`Chrome bounds were not normalized and fixed: ${JSON.stringify(calls)}`);
    }
    let failure = null;
    try {
      await stabilizeChromeWindow({
        Browser: {
          getWindowForTarget: async () => ({ windowId: 9 }),
          setWindowBounds: async () => { throw new Error("denied"); },
        },
      }, () => {});
    } catch (error) {
      failure = error;
    }
    if (!failure || !/stable Chrome window bounds.*denied/i.test(failure.message)) {
      throw new Error(`window-bounds failure was not explicit: ${failure?.message ?? "none"}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
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
        if (expression.includes("positionPattern")) return { result: { value: false } };
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
    if (!reloaded || evaluations !== 4) {
      throw new Error(`missing picker was not recovered by one bounded reload: reloaded=${reloaded}, evaluations=${evaluations}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/thinkingTime.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?picker-dismiss-test=${Date.now()}`);
    const events = [];
    let pickerProbes = 0;
    const runtime = {
      evaluate: async ({ expression }) => {
        if (expression.includes("positionPattern")) {
          pickerProbes += 1;
          return { result: { value: false } };
        }
        return { result: { value: { status: "already-selected", label: "Pro, item 5 of 5" } } };
      },
    };
    const logger = () => {};
    logger.verbose = false;
    const evidence = await module.ensureThinkingTime(runtime, "max", logger, null, {
      dispatchKeyEvent: async (event) => events.push(event),
    });
    if (!evidence.verified || pickerProbes !== 1 || events.length !== 2) {
      throw new Error(`verified picker was not dismissed with trusted Escape: probes=${pickerProbes}, events=${events.length}`);
    }

    let stickyPickerProbes = 0;
    const stickyRuntime = {
      evaluate: async ({ expression }) => {
        if (expression.includes("positionPattern")) {
          stickyPickerProbes += 1;
          return { result: { value: true } };
        }
        return { result: { value: { status: "already-selected", label: "Pro, item 5 of 5" } } };
      },
    };
    let stickyFailure = null;
    try {
      await module.ensureThinkingTime(stickyRuntime, "max", logger, null, {
        dispatchKeyEvent: async () => {},
      });
    } catch (error) {
      stickyFailure = error;
    }
    if (!stickyFailure || stickyPickerProbes !== 2 || !/selection unverified/i.test(stickyFailure.message)) {
      throw new Error(`open picker did not fail closed: probes=${stickyPickerProbes}, error=${stickyFailure?.message ?? "none"}`);
    }
    const assert = require("node:assert/strict");
    for (const probe of [undefined, { result: {} }, { exceptionDetails: { text: "probe failed" } }]) {
      await assert.rejects(module.ensureThinkingTime({
        evaluate: async ({ expression }) => expression.includes("positionPattern")
          ? probe : { result: { value: { status: "already-selected", label: "Pro, item 5 of 5" } } },
      }, "max", logger, null, { dispatchKeyEvent: async () => {} }), /selection unverified/);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/thinkingTime.js"

node -e '
  const fs = require("node:fs");
  const path = require("node:path");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const start = source.indexOf("export async function uploadAttachmentFile");
    const end = source.indexOf("export async function clearComposerAttachments", start);
    if (start < 0 || end < 0) throw new Error("attachment upload function not found");
    const implementation = source
      .slice(start, end)
      .replace("export async function uploadAttachmentFile", "async function uploadAttachmentFile");
    const makeUploader = (waitForAttachmentVisible) => new Function(
      "path",
      "INPUT_SELECTORS",
      "SEND_BUTTON_SELECTORS",
      "UPLOAD_STATUS_SELECTORS",
      "delay",
      "logDomFailure",
      "transferAttachmentViaDataTransfer",
      "waitForAttachmentVisible",
      "waitForAttachmentAnchored",
      `${implementation}; return uploadAttachmentFile;`,
    )(
      path,
      ["#prompt-textarea"],
      ["button[data-testid=send-button]"],
      [],
      async () => {},
      async () => {},
      async () => {},
      waitForAttachmentVisible,
      async () => false,
    );

    const runGenericCardScenario = async (generatedBundle, visibleProbe) => {
      let signalProbe = 0;
      const runtime = {
        evaluate: async ({ expression }) => {
          if (expression.includes("el.click()")) {
            return { result: { value: false } };
          }
          if (expression.includes("data-oracle-upload-candidate")) {
            return { result: { value: {
              ok: true,
              baselineChipCount: 0,
              baselineChips: [],
              baselineUploading: false,
              baselineFileCount: 0,
              baselineInputCount: 0,
              order: [0],
            } } };
          }
          if (expression.includes("normalizedExpected")) {
            signalProbe += 1;
            return { result: { value: {
              ui: false,
              input: false,
              inputCount: 0,
              chipCount: signalProbe === 1 ? 0 : 1,
              chipSignature: signalProbe === 1 ? "" : "14 个文件||||||file-pill",
              uploading: false,
              fileCount: 0,
            } } };
          }
          if (expression.includes("return { ok: true, x:")) {
            return { result: { value: { ok: false } } };
          }
          throw new Error(`unexpected attachment expression: ${expression.slice(0, 80)}`);
        },
      };
      return makeUploader(visibleProbe)(
        {
          runtime,
          dom: {
            getDocument: async () => ({ root: { nodeId: 1 } }),
            querySelector: async () => ({ nodeId: 2 }),
            setFileInputFiles: async () => {},
          },
          input: { dispatchMouseEvent: async () => {} },
        },
        {
          path: "/tmp/attachments-bundle.txt",
          displayPath: "attachments-bundle.txt",
          generatedBundle,
        },
        () => {},
        { expectedCount: 1 },
      );
    };

    let generatedVisibleProbes = 0;
    const generatedResult = await runGenericCardScenario(true, async () => {
      generatedVisibleProbes += 1;
      throw new Error("generated bundle was forced through exact-name visibility");
    });
    if (!generatedResult || generatedVisibleProbes !== 0) {
      throw new Error(`generated bundle did not accept its generic UI delta: probes=${generatedVisibleProbes}`);
    }

    let normalVisibleProbes = 0;
    const normalResult = await runGenericCardScenario(false, async () => {
      normalVisibleProbes += 1;
      throw new Error("normal attachment was forced through exact-name visibility");
    });
    if (!normalResult || normalVisibleProbes !== 0) {
      throw new Error(`normal attachment did not accept its generic UI delta: probes=${normalVisibleProbes}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/attachments.js"

node -e '
  const { pathToFileURL } = require("node:url");
  (async () => {
    const module = await import(`${pathToFileURL(process.argv[1]).href}?attachment-completion-test=${Date.now()}`);
    let probes = 0;
    const runtime = {
      evaluate: async () => {
        probes += 1;
        return { result: { value: {
          state: "disabled",
          uploading: false,
          filesAttached: true,
          attachedNames: ["1 个文件"],
          inputNames: [],
          fileCount: 0,
        } } };
      },
    };
    await module.waitForAttachmentCompletion(
      runtime,
      2500,
      [{ name: "oracle-web-live-probe.txt", generatedBundle: false }],
      () => {},
      { appearanceConfirmed: true },
    );
    if (probes < 2) {
      throw new Error(`generic attachment completion was not stabilized: probes=${probes}`);
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/attachments.js"

node -e '
  const fs = require("node:fs");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const start = source.indexOf("function isThinkingPointerAction");
    const end = source.indexOf("function buildThinkingTimeExpression", start);
    if (start < 0 || end < 0) throw new Error("thinking pointer refresh helpers are missing");
    const implementation = source.slice(start, end);
    const evaluateThinkingTimeSelection = new Function(
      "buildThinkingTimeExpression",
      "MENU_CONTAINER_SELECTOR",
      `${implementation}; return evaluateThinkingTimeSelection;`,
    )(() => "probe", "[role=menu]") ;
    const viewportBefore = {
      width: 1000, height: 700, visualWidth: 1000, visualHeight: 700,
      visualOffsetLeft: 0, visualOffsetTop: 0,
    };
    const viewportAfter = { ...viewportBefore, width: 1200, visualWidth: 1200 };
    const pointer = (x, viewport, hitTargetMatches = true) => ({
      status: "slider-click-required",
      purpose: "focus-power-slider",
      x,
      y: 90,
      viewport,
      hitTargetMatches,
    });
    const responses = [
      pointer(10, viewportBefore),
      pointer(60, viewportAfter),
      pointer(70, viewportAfter),
      pointer(80, viewportAfter),
      pointer(90, viewportAfter),
      { status: "already-selected", label: "第 4 项，共 5 项" },
      false,
    ];
    const events = [];
    const result = await evaluateThinkingTimeSelection({
      evaluate: async () => ({ result: { value: responses.shift() } }),
    }, "extra-high", null, {
      dispatchMouseEvent: async (event) => events.push(event),
      dispatchKeyEvent: async (event) => events.push(event),
    });
    const presses = events.filter((event) => event.type === "mousePressed");
    if (result?.status !== "already-selected" || presses.length !== 1 || presses[0].x !== 90) {
      throw new Error(`thinking click reused stale coordinates: result=${result?.status}, events=${JSON.stringify(events)}`);
    }

    const blockedEvents = [];
    const blockedResponses = [pointer(20, viewportBefore), pointer(20, viewportBefore, false)];
    const blocked = await evaluateThinkingTimeSelection({
      evaluate: async () => ({ result: { value: blockedResponses.shift() } }),
    }, "extra-high", null, {
      dispatchMouseEvent: async (event) => blockedEvents.push(event),
      dispatchKeyEvent: async (event) => blockedEvents.push(event),
    });
    if (blocked?.status !== "selection-unverified" || blockedEvents.length !== 0) {
      throw new Error(`unverified thinking target received input: ${JSON.stringify(blockedEvents)}`);
    }

    const noPointer = await evaluateThinkingTimeSelection({
      evaluate: async () => ({ result: { value: pointer(20, viewportBefore) } }),
    }, "extra-high", null, {
      dispatchKeyEvent: async () => {},
    });
    if (noPointer?.status !== "selection-unverified" || noPointer?.sliderPointerAvailable !== false) {
      throw new Error("thinking pointer fallback did not fail closed when CDP pointer input was unavailable");
    }

    const keyEvents = [];
    const keyResponses = [
      { status: "slider-key-required", key: "ArrowRight" },
      { status: "switched", label: "第 5 项，共 5 项" },
      false,
    ];
    const keyed = await evaluateThinkingTimeSelection({
      evaluate: async () => ({ result: { value: keyResponses.shift() } }),
    }, "max", null, {
      dispatchMouseEvent: async (event) => keyEvents.push(event),
      dispatchKeyEvent: async (event) => keyEvents.push(event),
    });
    const sliderKeyEvents = keyEvents.filter((event) => event.key === "ArrowRight");
    const dismissEvents = keyEvents.filter((event) => event.key === "Escape");
    if (
      keyed?.status !== "switched" ||
      sliderKeyEvents.length !== 2 ||
      dismissEvents.length !== 2 ||
      keyEvents.some((event) => event.type !== "keyDown" && event.type !== "keyUp")
    ) {
      throw new Error(`ARIA slider keyboard path was not preserved: ${JSON.stringify(keyEvents)}`);
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

    class FocusFallbackError extends Error {
      constructor(message, details) {
        super(message);
        this.details = details;
      }
    }
    const buildFocusFallbackSubmitter = (activeMatches, fallbackEvents) => factory(
      async () => {},
      () => "",
      ["#prompt-textarea", "textarea"],
      "#prompt-textarea",
      "textarea[name=prompt-textarea]",
      async () => {},
      async () => {},
      FocusFallbackError,
      async () => true,
      async () => true,
      async () => { fallbackEvents.push("enter"); },
      async () => true,
      async () => {
        throw new FocusFallbackError("covered composer", {
          stage: "submit-prompt",
          code: "trusted-target-mismatch",
          kind: "composer",
        });
      },
    );
    const buildFocusFallbackRuntime = (activeMatches) => {
      let fallbackEvaluation = 0;
      return {
        evaluate: async () => {
          fallbackEvaluation += 1;
          if (fallbackEvaluation === 1) {
            return { result: { value: {
              focused: true,
              activeMatches,
              x: 20,
              y: 30,
            } } };
          }
          if (fallbackEvaluation === 2) {
            return { result: { value: true } };
          }
          return { result: { value: {
            editorText: "probe",
            fallbackValue: "",
            activeValue: "probe",
          } } };
        },
      };
    };

    const focusFallbackEvents = [];
    const focusFallbackSubmitter = buildFocusFallbackSubmitter(true, focusFallbackEvents);
    await focusFallbackSubmitter({
      runtime: buildFocusFallbackRuntime(true),
      input: { insertText: async () => { focusFallbackEvents.push("insertText"); } },
      baselineTurns: 0,
    }, "probe", () => {});
    if (focusFallbackEvents.join(",") !== "insertText") {
      throw new Error(`verified composer focus did not recover a covered pointer target: ${focusFallbackEvents.join(",")}`);
    }

    const untrustedFocusEvents = [];
    const untrustedFocusSubmitter = buildFocusFallbackSubmitter(false, untrustedFocusEvents);
    let untrustedFocusError = null;
    try {
      await untrustedFocusSubmitter({
        runtime: buildFocusFallbackRuntime(false),
        input: { insertText: async () => { untrustedFocusEvents.push("insertText"); } },
        baselineTurns: 0,
      }, "probe", () => {});
    } catch (error) {
      untrustedFocusError = error;
    }
    if (
      untrustedFocusError?.details?.code !== "trusted-target-mismatch" ||
      untrustedFocusEvents.length !== 0
    ) {
      throw new Error("an unverified composer focus bypassed trusted pointer validation");
    }

    const staleFocusEvents = [];
    let staleFocusEvaluation = 0;
    let staleFocusError = null;
    try {
      await focusFallbackSubmitter({
        runtime: {
          evaluate: async () => {
            staleFocusEvaluation += 1;
            if (staleFocusEvaluation === 1) {
              return { result: { value: {
                focused: true,
                activeMatches: true,
                x: 20,
                y: 30,
              } } };
            }
            return { result: { value: false } };
          },
        },
        input: { insertText: async () => { staleFocusEvents.push("insertText"); } },
        baselineTurns: 0,
      }, "probe", () => {});
    } catch (error) {
      staleFocusError = error;
    }
    if (
      staleFocusError?.details?.code !== "trusted-target-mismatch" ||
      staleFocusEvents.length !== 0
    ) {
      throw new Error("a stale composer focus reached prompt insertion");
    }

    const unreadableEvents = [];
    const unreadableSubmitter = factory(
      async () => {},
      () => "",
      ["#prompt-textarea", "textarea"],
      "#prompt-textarea",
      "textarea[name=prompt-textarea]",
      async () => {},
      async () => {},
      FocusFallbackError,
      async () => true,
      async () => true,
      async () => { unreadableEvents.push("enter"); },
      async () => true,
      async () => {},
    );
    let unreadableEvaluation = 0;
    let unreadableError = null;
    try {
      await unreadableSubmitter({
        runtime: {
          evaluate: async () => {
            unreadableEvaluation += 1;
            if (unreadableEvaluation === 1) {
              return { result: { value: { focused: true } } };
            }
            return { result: { value: {
              editorText: "",
              fallbackValue: "",
              activeValue: "",
            } } };
          },
        },
        input: { insertText: async () => { unreadableEvents.push("insertText"); } },
        baselineTurns: 0,
      }, "probe", () => {});
    } catch (error) {
      unreadableError = error;
    }
    if (
      unreadableError?.details?.code !== "prompt-insertion-unverified" ||
      unreadableEvents.join(",") !== "insertText"
    ) {
      throw new Error("an unreadable prompt insertion reached the send path");
    }
  })().catch((error) => { console.error(error.message); process.exit(1); });
' "$test_root/package/dist/src/browser/actions/promptComposer.js"

node -e '
  const fs = require("node:fs");
  (async () => {
    const source = fs.readFileSync(process.argv[1], "utf8");
    const start = source.indexOf("function buildTrustedPointExpression");
    const end = source.indexOf("async function waitForSubmissionStart", start);
    if (start < 0 || end < 0) throw new Error("trusted target helpers are missing");
    const implementation = source.slice(start, end);
    if (
      !implementation.includes("document.elementFromPoint") ||
      implementation.includes("visibilityState") ||
      implementation.includes(".click()")
    ) {
      throw new Error("trusted click must use DOM hit testing and CDP input without depending on tab visibility");
    }
    const trustedTargetHelpers = new Function(
      "INPUT_SELECTORS",
      "SEND_BUTTON_SELECTORS",
      "PROMPT_PRIMARY_SELECTOR",
      "BrowserAutomationError",
      `${implementation}; return { buildTrustedPointExpression, clickTrustedPoint };`,
    )(
      ["#prompt-textarea"],
      ["button[data-testid=send-button]"],
      "#prompt-textarea",
      class BrowserAutomationError extends Error {},
    );
    const { buildTrustedPointExpression, clickTrustedPoint } = trustedTargetHelpers;
    class FakeNode {}
    class FakeElement extends FakeNode {
      constructor(name) {
        super();
        this.name = name;
        this.isContentEditable = name === "composer";
      }
      getBoundingClientRect() {
        return { left: 0, top: 0, width: 400, height: 160 };
      }
      getAttribute(name) {
        return name === "contenteditable" && this.isContentEditable ? "true" : null;
      }
      hasAttribute() { return false; }
      contains(node) { return node === this; }
      scrollIntoView() {}
    }
    class FakeTextAreaElement extends FakeElement {}
    class FakeInputElement extends FakeElement {}
    const composer = new FakeElement("composer");
    const attachmentCard = new FakeElement("attachment-card");
    const composerExpression = buildTrustedPointExpression("composer");
    const composerPoint = vm.runInNewContext(composerExpression, {
      Node: FakeNode,
      HTMLElement: FakeElement,
      HTMLTextAreaElement: FakeTextAreaElement,
      HTMLInputElement: FakeInputElement,
      document: {
        activeElement: composer,
        querySelector: () => composer,
        querySelectorAll: () => [composer],
        elementFromPoint: (x, y) => x === 200 && y === 80 ? attachmentCard : composer,
      },
      window: {
        innerWidth: 1000,
        innerHeight: 700,
        visualViewport: null,
        getComputedStyle: () => ({ pointerEvents: "auto" }),
      },
    });
    if (
      composerPoint?.status !== "point" ||
      composerPoint.kind !== "composer" ||
      (composerPoint.x === 200 && composerPoint.y === 80)
    ) {
      throw new Error(`valid composer point was not recovered around an attachment overlay: ${JSON.stringify(composerPoint)}`);
    }
    const viewportBefore = {
      width: 1000, height: 700, visualWidth: 1000, visualHeight: 700,
      visualOffsetLeft: 0, visualOffsetTop: 0,
    };
    const viewportAfter = { ...viewportBefore, width: 1200, visualWidth: 1200 };
    let evaluations = 0;
    const runtime = {
      evaluate: async () => ({
        result: {
          value: ++evaluations === 1
            ? { status: "point", kind: "send", x: 20, y: 30, viewport: viewportAfter }
            : { status: "point", kind: "send", x: 80, y: 90, viewport: viewportAfter },
        },
      }),
    };
    const events = [];
    const input = {
      dispatchMouseEvent: async (event) => events.push(event),
    };
    await clickTrustedPoint(runtime, input, {
      status: "point", kind: "send", x: 10, y: 10, viewport: viewportBefore,
    });
    if (
      evaluations !== 2 ||
      events.length !== 2 ||
      events.some((event) => event.x !== 80 || event.y !== 90)
    ) {
      throw new Error(`stale coordinates were not discarded after resize: evaluations=${evaluations}, events=${JSON.stringify(events)}`);
    }
    const blockedEvents = [];
    let blocked = null;
    try {
      await clickTrustedPoint({
        evaluate: async () => ({ result: { value: {
          status: "target-mismatch", kind: "send", x: 20, y: 30, viewport: viewportBefore,
        } } }),
      }, {
        dispatchMouseEvent: async (event) => blockedEvents.push(event),
      }, {
        status: "point", kind: "send", x: 20, y: 30, viewport: viewportBefore,
      });
    } catch (error) {
      blocked = error;
    }
    if (!blocked || blockedEvents.length !== 0 || !/hit testing/i.test(blocked.message)) {
      throw new Error(`mismatched hit target was clicked or not reported: ${blocked?.message ?? "none"}`);
    }
    let unavailable = null;
    try {
      await clickTrustedPoint({
        evaluate: async () => ({ result: { value: {
          status: "point", kind: "composer", x: 20, y: 30, viewport: viewportBefore,
        } } }),
      }, {}, {
        status: "point", kind: "composer", x: 20, y: 30, viewport: viewportBefore,
      });
    } catch (error) {
      unavailable = error;
    }
    if (!unavailable || !/requires CDP pointer input/i.test(unavailable.message)) {
      throw new Error(`missing trusted input did not fail closed: ${unavailable?.message ?? "none"}`);
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
  const vm = require("node:vm");
  (async () => {
      const source = fs.readFileSync(process.argv[1], "utf8");
      const enterStart = source.indexOf("async function submitViaEnter");
      const enterEnd = source.indexOf("export async function clearPromptComposer", enterStart);
      if ([enterStart, enterEnd].some((index) => index < 0)) {
        throw new Error("Enter fallback source not found");
      }
      const factory = new Function(
        "INPUT_SELECTORS",
        "PROMPT_PRIMARY_SELECTOR",
        "ENTER_KEY_EVENT",
        "ENTER_KEY_TEXT",
        "BrowserAutomationError",
        "hasFocusedVisibleComposer",
        "clickTrustedPoint",
        `${source.slice(enterStart, enterEnd)}; return submitViaEnter;`,
      );
      class EnterFallbackError extends Error {
        constructor(message, details) {
          super(message);
          this.details = details;
        }
      }
      const submitViaEnter = factory(
        ["#prompt-textarea", "textarea"],
        "#prompt-textarea",
        { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 },
        "\\r",
        EnterFallbackError,
        async () => true,
        async (_runtime, _input, point) => {
          events.push(`mousePressed:${point.x}`);
          events.push(`mouseReleased:${point.x}`);
        },
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
                Node: class {},
                HTMLTextAreaElement: FakeTextarea,
                HTMLInputElement: class {},
                window: {
                  innerWidth: 1280,
                  innerHeight: 720,
                  visualViewport: null,
                },
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

      const coveredEvents = [];
      const coveredSubmitViaEnter = factory(
        ["#prompt-textarea"],
        "#prompt-textarea",
        { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 },
        "\\r",
        EnterFallbackError,
        async () => true,
        async () => {
          throw new EnterFallbackError("covered composer", {
            stage: "submit-prompt",
            code: "trusted-target-mismatch",
            kind: "composer",
          });
        },
      );
      await coveredSubmitViaEnter(
        { evaluate: async () => ({ result: { value: {
          activeMatches: true,
          kind: "composer",
          x: 20,
          y: 30,
        } } }) },
        { dispatchKeyEvent: async ({ type }) => coveredEvents.push(type) },
      );
      if (coveredEvents.join(",") !== "keyDown,keyUp") {
        throw new Error(`verified Enter focus did not recover a covered pointer target: ${coveredEvents.join(",")}`);
      }

      const untrustedEnterEvents = [];
      let untrustedEnterError = null;
      try {
        await coveredSubmitViaEnter(
          { evaluate: async () => ({ result: { value: {
            activeMatches: false,
            kind: "composer",
            x: 20,
            y: 30,
          } } }) },
          { dispatchKeyEvent: async ({ type }) => untrustedEnterEvents.push(type) },
        );
      } catch (error) {
        untrustedEnterError = error;
      }
      if (
        untrustedEnterError?.details?.code !== "trusted-target-mismatch" ||
        untrustedEnterEvents.length !== 0
      ) {
        throw new Error("an unverified Enter focus bypassed trusted pointer validation");
      }

      const staleEnterEvents = [];
      const staleSubmitViaEnter = factory(
        ["#prompt-textarea"],
        "#prompt-textarea",
        { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 },
        "\\r",
        EnterFallbackError,
        async () => false,
        async () => {
          throw new EnterFallbackError("covered composer", {
            stage: "submit-prompt",
            code: "trusted-target-mismatch",
            kind: "composer",
          });
        },
      );
      let staleEnterError = null;
      try {
        await staleSubmitViaEnter(
          { evaluate: async () => ({ result: { value: {
            activeMatches: true,
            kind: "composer",
            x: 20,
            y: 30,
          } } }) },
          { dispatchKeyEvent: async ({ type }) => staleEnterEvents.push(type) },
        );
      } catch (error) {
        staleEnterError = error;
      }
      if (
        staleEnterError?.details?.code !== "trusted-target-mismatch" ||
        staleEnterEvents.length !== 0
      ) {
        throw new Error("a stale Enter focus reached keyboard submission");
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
      client: { close: () => { calls.push("client.close"); } },
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
mkdir -p "$profile_source/Default/Network" "$profile_source/Default/Local Storage/leveldb" "$profile_source/Default/Sessions" "$test_root/fake-path"
printf '%s\n' '{"profile":{"last_used":"Default"}}' > "$profile_source/Local State"
printf '%s\n' '{"profile":{"exit_type":"Crashed","exited_cleanly":false}}' > "$profile_source/Default/Preferences"
printf '%s\n' 'test-cookie-database-placeholder' > "$profile_source/Default/Network/Cookies"
printf '%s\n' 'routing-state-must-not-cross' > "$profile_source/Default/Local Storage/leveldb/000003.log"
printf '%s\n' 'tab-restore-must-not-cross' > "$profile_source/Default/Sessions/Tabs"
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
[[ ! -e "$profile_dest/Default/Local Storage" ]] || \
  oracle_web_die "copied Profile carried client-side Local Storage (conversation-routing state)"
[[ ! -e "$profile_dest/Default/Sessions" ]] || \
  oracle_web_die "copied Profile carried session restore data"

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

mkdir -p "$test_root/chrome/Profile 2/Network"
printf '%s\n' '{}' > "$test_root/chrome/Local State"
printf '%s\n' 'placeholder' > "$test_root/chrome/Profile 2/Network/Cookies"

doctor_output="$(
  ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_CHROME_USER_DATA_DIR="$test_root/chrome" \
  ORACLE_WEB_CHROME_PROFILE="Profile 2" \
  "$test_root/bin/oracle-web" --doctor
)"
grep -Fq "wrapper=$test_root/bin/oracle-web" <<< "$doctor_output"
grep -Fq "chromeUserDataDir=$test_root/chrome" <<< "$doctor_output"
grep -Fq 'chromeProfile=Profile 2' <<< "$doctor_output"
grep -Fq 'cookieDb=Network/Cookies' <<< "$doctor_output"
grep -Fq 'loginState=not-tested' <<< "$doctor_output"

if ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_CHROME_USER_DATA_DIR="$test_root/missing-chrome" \
  "$test_root/bin/oracle-web" --doctor >"$test_root/doctor-failure.log" 2>&1; then
  oracle_web_die "wrapper doctor accepted a missing Chrome profile"
fi

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
[[ "$(grep -c '^ARG=--browser-cookie-path$' <<< "$wrapper_output")" -eq 0 ]]
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
grep -q '^ARG=max$' <<< "$default_wrapper_output"
[[ "$(grep -c '^ARG=--browser-attachment-timeout$' <<< "$default_wrapper_output")" -eq 1 ]]
grep -q '^ARG=300s$' <<< "$default_wrapper_output"
[[ "$(grep -c '^ARG=--timeout$' <<< "$default_wrapper_output")" -eq 1 ]]
[[ "$(grep -c '^ARG=--browser-timeout$' <<< "$default_wrapper_output")" -eq 1 ]]
[[ "$(grep -c '^ARG=45m$' <<< "$default_wrapper_output")" -eq 2 ]]

override_wrapper_output="$(
  ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_SESSION_DIR="$test_root/override-sessions" \
  "$test_root/bin/oracle-web" --browser-attachment-timeout 90s -p probe
)"
[[ "$(grep -c '^ARG=--browser-attachment-timeout$' <<< "$override_wrapper_output")" -eq 1 ]]
grep -q '^ARG=90s$' <<< "$override_wrapper_output"

timeout_override_output="$(
  ORACLE_WEB_ORACLE_BIN="$fake_oracle" \
  ORACLE_WEB_SESSION_DIR="$test_root/timeout-override-sessions" \
  "$test_root/bin/oracle-web" --timeout 12m --browser-timeout 12m -p probe
)"
[[ "$(grep -c '^ARG=--timeout$' <<< "$timeout_override_output")" -eq 1 ]]
[[ "$(grep -c '^ARG=--browser-timeout$' <<< "$timeout_override_output")" -eq 1 ]]
[[ "$(grep -c '^ARG=12m$' <<< "$timeout_override_output")" -eq 2 ]]

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
  --browser-chrome-profile=Default \
  --copy-profile="$test_root/chrome" \
  --browser-manual-login \
  --browser-cookie-path="$test_root/chrome/Profile 2/Cookies" \
  --browser-inline-cookies='[]' \
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

cleanup_state="$test_root/cleanup-state"
cleanup_slug="completed-cleanup-probe"
cleanup_profile="$test_root/already-removed-profile"
mkdir -p "$cleanup_state/sessions/$cleanup_slug"
node -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    status: "completed",
    browser: { runtime: {
      promptSubmitted: true,
      chromePid: 99999999,
      chromeTargetId: "target-cleanup-probe",
      userDataDir: process.argv[2],
    } },
  }));
' "$cleanup_state/sessions/$cleanup_slug/meta.json" "$cleanup_profile"
oracle_web_assert_session_cleanup "$cleanup_state" "$cleanup_slug" 1

alive_cleanup_slug="alive-cleanup-probe"
mkdir -p "$cleanup_state/sessions/$alive_cleanup_slug"
node -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    status: "completed",
    browser: { runtime: {
      promptSubmitted: true,
      chromePid: process.ppid,
      chromeTargetId: "target-alive-probe",
      userDataDir: process.argv[2],
    } },
  }));
' "$cleanup_state/sessions/$alive_cleanup_slug/meta.json" "$cleanup_profile"
if (oracle_web_assert_session_cleanup "$cleanup_state" "$alive_cleanup_slug" 1) \
  >"$test_root/alive-cleanup.log" 2>&1; then
  oracle_web_die "session cleanup verification accepted a live recorded Chrome PID"
fi
grep -q 'left recorded Chrome PID' "$test_root/alive-cleanup.log" || \
  oracle_web_die "session cleanup verification did not explain the live Chrome failure"

grep -Fq 'oracle_web_assert_session_cleanup "$session_dir" "$slug"' "$script_dir/live-smoke.sh" || \
  oracle_web_die "live smoke does not verify its exact session cleanup"

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
[[ ! -e "$test_root/claude-home/skills/oracle-web/SKILL.md" ]] || \
  oracle_web_die "uninstall left managed Claude Skill files behind"

mkdir -p "$test_root/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo user-owned wrapper' > "$test_root/bin/oracle-web"
chmod 0755 "$test_root/bin/oracle-web"
if "$script_dir/install.sh" >"$test_root/conflict.log" 2>&1; then
  oracle_web_die "installer overwrote a conflicting wrapper without --force"
fi
[[ "$(oracle_web_patch_state "$test_root/package")" == "pristine" ]] || \
  oracle_web_die "installer modified runtime before reporting a destination conflict"
rm -f "$test_root/bin/oracle-web"

mkdir -p "$test_root/claude-home/skills/oracle-web"
printf '%s\n' 'user-owned Claude Skill' > "$test_root/claude-home/skills/oracle-web/SKILL.md"
if "$script_dir/install.sh" >"$test_root/claude-conflict.log" 2>&1; then
  oracle_web_die "installer overwrote a conflicting Claude Skill without --force"
fi
[[ "$(oracle_web_patch_state "$test_root/package")" == "pristine" ]] || \
  oracle_web_die "installer modified runtime before reporting a Claude Skill conflict"
rm -f "$test_root/claude-home/skills/oracle-web/SKILL.md"
rmdir "$test_root/claude-home/skills/oracle-web" 2>/dev/null || true

printf '%s\n' '// unknown local drift' >> "$test_root/package/dist/src/browser/actions/attachments.js"
if "$script_dir/install.sh" --force >"$test_root/drift.log" 2>&1; then
  oracle_web_die "installer accepted an unknown Oracle runtime"
fi

echo "All offline tests passed"
