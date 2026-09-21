import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const runtimeRoot = process.argv[2];
const require = createRequire(path.join(runtimeRoot, 'package.json'));
const { launch } = require('chrome-launcher');
const CDP = require('chrome-remote-interface');
const { uploadAttachmentFile, waitForAttachmentCompletion } = await import(pathToFileURL(path.join(runtimeRoot, 'dist/src/browser/actions/attachments.js')));
const { buildAttachmentReadyExpressionForTest } = await import(pathToFileURL(path.join(runtimeRoot, 'dist/src/browser/actions/promptComposer.js')));
const { buildConversationTurnListExpression } = await import(pathToFileURL(path.join(runtimeRoot, 'dist/src/browser/conversationTurns.js')));
const { readAssistantSnapshot } = await import(pathToFileURL(path.join(runtimeRoot, 'dist/src/browser/actions/assistantResponse.js')));
const { buildThinkingTimeExpressionForTest } = await import(pathToFileURL(path.join(runtimeRoot, 'dist/src/browser/actions/thinkingTime.js')));
const profile = mkdtempSync(path.join(tmpdir(), 'oracle-web-dom-test-'));
let chrome;
let client;
try {
  chrome = await launch({
    startingUrl: 'about:blank', userDataDir: profile,
    chromeFlags: ['--headless=new', '--no-first-run', '--disable-background-networking'],
  });
  client = await CDP({ port: chrome.port });
  // 来自实际页面的最小结构：没有旧 editor ID，文件卡片没有旧 testid，input 上传后被清空。
  const markup = `<form data-chatgpt-composer>
    <input type="file" multiple accept="image/*,video/*" aria-label="Attach photos or videos" hidden>
    <input type="file" multiple accept="image/*" aria-label="附加照片" hidden>
    <input type="file" multiple aria-label="附加文件" hidden>
    <div data-composer-attachments><div id="cards"></div></div>
    <div contenteditable="true" role="textbox" class="ProseMirror" aria-label="给 ChatGPT 发消息"></div>
    <button type="submit" aria-label="发送">发送</button>
  </form>`;
  const card = name => `<span class="group/composer-attachment">
    <span class="composer-attachment-surface"><span>${name}</span><button type="button" aria-label="${name}"></button></span>
    <button type="button" aria-label="移除 ${name}">×</button>
  </span>`;
  const evaluate = args => client.Runtime.evaluate({ ...args, returnByValue: true });
  await evaluate({ expression: `document.body.innerHTML = ${JSON.stringify(markup)}` });
  let dispatched = 0;
  let observingNewUpload = false;
  const logger = () => {};
  const runtime = { evaluate: async args => {
    const result = await evaluate(args);
    assert.equal(result.exceptionDetails, undefined, 'DOM probe threw instead of observing the page');
    if (observingNewUpload && args.expression.includes('const normalizedExpected =')) {
      assert.equal(result.result.value.ui, true, 'Visible renamed Chinese attachment was missed');
    }
    return result;
  } };
  for (const name of ['probe-one.txt', 'probe-two.md']) {
    observingNewUpload = false;
    await uploadAttachmentFile({ runtime, input: client.Input, dom: {
      getDocument: args => client.DOM.getDocument(args),
      querySelector: args => client.DOM.querySelector(args),
      setFileInputFiles: async () => {
        dispatched += 1;
        observingNewUpload = true;
        const displayName = name.replace('.', '(20260920-152709).');
        await evaluate({ expression: `document.querySelector('#cards').insertAdjacentHTML('beforeend', ${JSON.stringify(card(displayName))})` });
      },
    } }, { path: `/tmp/${name}` }, logger);
    assert.equal(dispatched, name === 'probe-one.txt' ? 1 : 2, 'Attachment was uploaded more than once');
  }
  const names = ['probe-one.txt', 'probe-two.md'];
  await waitForAttachmentCompletion(runtime, 3000, names, logger, { appearanceConfirmed: true });
  const ready = await evaluate({ expression: buildAttachmentReadyExpressionForTest(names) });
  assert.equal(ready.result.value, true, 'Send readiness missed the current attachment cards');
  await evaluate({ expression: `document.querySelector('#cards').innerHTML = ''; document.querySelector('[contenteditable]').textContent = 'probe-one.txt probe-two.md'` });
  const empty = await evaluate({ expression: buildAttachmentReadyExpressionForTest(names) });
  assert.equal(empty.result.value, false, 'Filename text in a prompt was accepted as an attachment');
  await evaluate({ expression: `document.querySelector('[contenteditable]').textContent = ''` });
  let ambiguousUploads = 0;
  await assert.rejects(uploadAttachmentFile({
    runtime: { evaluate }, input: client.Input, dom: {
      getDocument: args => client.DOM.getDocument(args),
      querySelector: args => client.DOM.querySelector(args),
      setFileInputFiles: async () => { ambiguousUploads += 1; },
    },
  }, { path: '/tmp/no-acknowledgment.txt' }, logger), /refusing duplicate upload/);
  assert.equal(ambiguousUploads, 1, 'Unknown upload outcome was retried');
  const conversation = `<main>
    <div data-user-message-bubble="true">Read this file and reply ORACLE-WEB-LIVE-OK</div>
    <div data-content-search-unit-key="test-message:2:assistant">
      <h6>ChatGPT 说：</h6>
      <div data-markdown-text-style="assistant-message"><p>ORACLE-WEB-LIVE-OK</p></div>
    </div>
  </main>`;
  await evaluate({ expression: `document.body.innerHTML = ${JSON.stringify(conversation)}` });
  const turns = await evaluate({ expression: `(${buildConversationTurnListExpression()}).map(n=>n.innerText)` });
  assert.equal(turns.result.value.length, 2, 'Current user/assistant messages were omitted from turn counting');
  const answer = await readAssistantSnapshot({ evaluate });
  assert.equal(answer?.text?.trim(), 'ORACLE-WEB-LIVE-OK', 'Assistant capture missed the answer or included the user prompt');
  await evaluate({ expression: `document.querySelector('[data-markdown-text-style]').remove()` });
  assert.equal(await readAssistantSnapshot({ evaluate }), null, 'User prompt was captured as an assistant answer');
  // 新菜单保留可聚焦的强度行和 ARIA thumb，但移除了旧 simple-view testid。
  const picker = `<form><button aria-haspopup="menu" aria-expanded="true" aria-controls="picker" aria-label="选择 ChatGPT 模型">思考强度</button></form>
    <div role="menu" id="picker" data-state="open" tabindex="-1">
      <span id="position">Pro，第 5 项，共 5 项</span>
      <div role="menuitem" aria-label="强度" tabindex="-1" style="width:246px;height:32px">
        <span role="slider" aria-hidden="true" tabindex="-1" aria-valuemin="0" aria-valuemax="4" aria-valuenow="4"></span>
      </div>
    </div>`;
  await evaluate({ expression: `document.body.innerHTML = ${JSON.stringify(picker)}; document.querySelector('[role=menuitem]').focus()` });
  const lower = await evaluate({ expression: buildThinkingTimeExpressionForTest('extra-high'), awaitPromise: true });
  assert.equal(lower.result.value?.status, 'slider-key-required', 'Current picker cannot change away from its existing position');
  assert.equal(lower.result.value.key, 'ArrowLeft');
  await evaluate({ expression: `document.querySelector('#position').textContent = '第 4 项，共 5 项'; document.querySelector('[role=slider]').setAttribute('aria-valuenow', '3')` });
  const higher = await evaluate({ expression: buildThinkingTimeExpressionForTest('max'), awaitPromise: true });
  assert.equal(higher.result.value?.status, 'slider-key-required');
  assert.equal(higher.result.value.key, 'ArrowRight');
  console.log('Native composer DOM regression passed (no ChatGPT connection)');
} finally {
  if (client) await client.close();
  if (chrome) await chrome.kill();
  rmSync(profile, { recursive: true, force: true });
}
