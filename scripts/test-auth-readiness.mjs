import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const { buildLoginProbeExpressionForTest, ensurePromptReady } = await import(pathToFileURL(path.join(process.argv[2], 'dist/src/browser/actions/navigation.js')));

class VisibleButton {
  constructor(text) { this.textContent = text; }
  getBoundingClientRect() { return { width: 120, height: 32 }; }
  getAttribute() { return null; }
}

const probe = async ({ label, redirect = false }) => {
  const location = { href: 'https://chatgpt.com/', pathname: '/', hostname: 'chatgpt.com' };
  const document = {
    querySelectorAll: () => label ? [new VisibleButton(label)] : [],
    querySelector: () => null,
  };
  const fetch = async () => ({
    status: 200,
    json: async () => {
      if (redirect) {
        location.href = 'https://chatgpt.com/auth/login';
        location.pathname = '/auth/login';
      }
      return { user: { id: 'synthetic-test-user' } };
    },
  });
  const run = new Function('document', 'window', 'HTMLElement', 'fetch', 'location', `return ${buildLoginProbeExpressionForTest(100)};`);
  return run(document, { getComputedStyle: () => ({ display: 'block', visibility: 'visible' }) }, VisibleButton, fetch, location);
};

const redirected = await probe({ redirect: true });
assert.equal(redirected.sessionAuthenticated, true);
assert.equal(redirected.onAuthPage, true, 'Authentication used the URL from before an awaited request');
assert.equal(redirected.ok, false, 'A late login redirect was accepted as a signed-in page');
assert.equal(redirected.pageUrl, 'https://chatgpt.com/auth/login');
for (const label of ['登录', '登录或注册', '使用 Google 账户继续', 'Log in']) {
  const result = await probe({ label });
  assert.equal(result.domLoginCta, true, `Visible login action was missed: ${label}`);
  assert.equal(result.ok, false);
}
assert.equal((await probe({})).ok, true, 'A valid session on a normal page was rejected');

let failure;
try {
  await ensurePromptReady({ evaluate: async () => ({ result: { value: 'https://chatgpt.com/auth/login?token=synthetic-secret#fragment' } }) }, 0, () => {}, { requireFreshConversation: true });
} catch (error) { failure = error; }
assert.ok(failure);
assert.match(failure.message, /authentication|login/i, 'Login redirect was reported as an editor timeout');
assert.equal(failure.details?.stage, 'prompt-ready');
assert.equal(failure.details?.pageUrl, 'https://chatgpt.com/auth/login');
assert.ok(!failure.message.includes('synthetic-secret') && !JSON.stringify(failure.details).includes('synthetic-secret'), 'Auth query leaked into diagnostics');
console.log('Authentication readiness regression passed: delayed redirect, localized login, sanitized failure');
