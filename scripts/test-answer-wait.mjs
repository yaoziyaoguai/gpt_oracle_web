import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

const root = process.argv[2];
const { createTerminalGateState, classifyTurnTerminal, waitForAssistantResponse, readAssistantSnapshot, buildCompletionVisibilityExpressionForTest, buildStopButtonVisibilityExpressionForTest } = await import(pathToFileURL(path.join(root, 'dist/src/browser/actions/assistantResponse.js')));
const config = { barConfirmCycles: 3, minStableMs: 1200, quietStableMs: 8000 };
const sample = { len: 21, contentKey: 'current-turn::a stationary thinking heading', stopVisible: false, barVisible: false, strongThinkingActive: false };
let state = createTerminalGateState(0);
for (const now of [0, 8100, 60_000, 20 * 60_000, 45 * 60_000]) {
  const decision = classifyTurnTerminal(state, { ...sample, now }, config);
  assert.equal(decision.terminal, false, `A heading without completion evidence was finalized after ${now}ms`);
  state = decision.state;
}
for (const veto of [{stopVisible:true}, {strongThinkingActive:true}, {stopVisible:null}, {strongThinkingActive:null}, {barVisible:null}]) {
  state = createTerminalGateState(0);
  for (const now of [0, 400, 800, 1200, 60_000]) {
    const decision = classifyTurnTerminal(state, {...sample, barVisible:true, ...veto, now}, config);
    assert.equal(decision.terminal,false,'Active or unobservable generation was finalized');
    state = decision.state;
  }
}
state = createTerminalGateState(0);
for (const now of [0, 400, 800, 1200]) {
  const decision = classifyTurnTerminal(state, {...sample, barVisible:true, now}, config);
  assert.equal(decision.terminal,now===1200,'Current-turn completion must be debounced');
  state=decision.state;
}
const changed = classifyTurnTerminal(state,{...sample,barVisible:true,now:1600,contentKey:'current-turn::same-length rewritten text'},config);
assert.equal(changed.terminal,false,'A rewritten answer reused stale completion evidence');
console.log('Answer completion gate regression passed');

const require = createRequire(path.join(root, 'package.json'));
const { launch } = require('chrome-launcher');
const CDP = require('chrome-remote-interface');
const profile = mkdtempSync(path.join(tmpdir(), 'oracle-answer-wait-test-'));
let chrome, client;
try {
  chrome = await launch({startingUrl:'about:blank', userDataDir:profile, chromeFlags:['--headless=new','--no-first-run','--disable-background-networking']});
  client = await CDP({port:chrome.port});
  const evaluate = args => client.Runtime.evaluate({...args,returnByValue:true});
  const setBody = html => evaluate({expression:`document.body.innerHTML = ${JSON.stringify(html)}`});
  const sleep = ms => new Promise(resolve=>setTimeout(resolve,ms));
  // 来自生成中网页：思考标题沿用 assistant 样式，但没有最终回答的 assistant 单元。
  await setBody('<main><div data-user-message-bubble="true">Current request</div><div class="block-BQZwFn"><button class="group/activity-header" aria-expanded="true">正在思考</button><div data-markdown-text-style="assistant-message" data-markdown-text-tone="tertiary">整理了验证方法</div></div><form data-chatgpt-composer><button aria-label="停止"></button></form></main>');
  assert.equal(await readAssistantSnapshot({evaluate},1),null,'A live reasoning heading was extracted as answer content');
  const stopProbe=await evaluate({expression:buildStopButtonVisibilityExpressionForTest()});
  assert.equal(stopProbe.result.value,true,'The observed Chinese generation stop control was missed');
  const modernActions='<div class="turn-action-controls"><button aria-label="复制"></button><button aria-label="评价回复"></button><button aria-label="重新生成回复"></button></div>';
  // 正文中的代码也带 markdown 类名，不能让子节点覆盖整个回答。
  await setBody('<main><div data-content-search-unit-key="current:2:assistant"><div data-markdown-text-style="assistant-message"><p>Route explanation <code class="inline-markdown">costs[u][v]</code></p><pre class="markdown-code">solve(costs)</pre><p>RESULT {"cost":153}</p></div></div></main>');
  const codeSnapshot=await readAssistantSnapshot({evaluate},0);
  assert.match(codeSnapshot.text,/Route explanation/,'Inline code replaced the whole assistant answer');
  assert.match(codeSnapshot.text,/RESULT/, 'The end of the answer was truncated');
  const modernAnswer='<div data-content-search-unit-key="current:2:assistant"><div data-markdown-text-style="assistant-message">Complete answer</div></div>';
  const previousExchange='<div data-content-search-turn-key="previous"><div data-content-search-unit-key="previous:2:assistant"><div data-markdown-text-style="assistant-message">Previous answer</div></div>'+modernActions+'</div>';
  await setBody('<main>'+previousExchange+'<div data-content-search-turn-key="current"><div data-user-message-bubble="true">Question</div><div id="before"></div>'+modernAnswer+'<div id="after"></div></div></main>');
  const modernSnapshot=await readAssistantSnapshot({evaluate},2);
  const modernCompletion=()=>evaluate({expression:buildCompletionVisibilityExpressionForTest(modernSnapshot,2)}).then(r=>r.result.value);
  assert.equal(await modernCompletion(),false,'An older exchange toolbar proved current completion');
  await evaluate({expression:`document.querySelector('#before').innerHTML=${JSON.stringify(modernActions)}`});
  assert.equal(await modernCompletion(),false,'A toolbar before the answer proved completion');
  await evaluate({expression:`document.querySelector('#before').innerHTML='';document.querySelector('#after').innerHTML=${JSON.stringify(modernActions)}`});
  assert.equal(await modernCompletion(),true,'The observed sibling completion toolbar was missed');
  const actions = '<button data-testid="copy-turn-action-button">Copy</button>';
  const current = text => `<div data-content-search-unit-key="new:2:assistant"><div data-markdown-text-style="assistant-message">${text}</div><div id="actions"></div></div>`;
  const prefix = `<main><div data-content-search-unit-key="old:0:assistant"><div data-markdown-text-style="assistant-message">Earlier answer</div>${actions}</div><div data-user-message-bubble="true">Current request</div>`;
  await setBody(prefix+current('A heading waiting for a long reasoning phase')+'</main>');
  let snapshot = await readAssistantSnapshot({evaluate},2);
  const completion = () => evaluate({expression:buildCompletionVisibilityExpressionForTest(snapshot,2)}).then(r=>r.result.value);
  assert.equal(await completion(),false,'Previous turn controls proved the current turn complete');
  await evaluate({expression:`document.querySelector('#actions').innerHTML = ${JSON.stringify(actions)}`});
  assert.equal(await completion(),true,'Current assistant-unit sibling controls were missed');
  await evaluate({expression:`document.querySelector('#actions').style.display='none'`});
  assert.equal(await completion(),false,'Hidden controls proved completion');
  await evaluate({expression:`document.querySelector('#actions').removeAttribute('style'); document.querySelector('#actions').innerHTML=''`});

  // 真实等待函数同时启动 observer 和 watchdog；标题静止超过旧 8 秒阈值仍需继续等待。
  let settled = false;
  const pending = waitForAssistantResponse({evaluate,terminateExecution:()=>client.Runtime.terminateExecution()},30_000,()=>{},2);
  pending.then(()=>{settled=true},()=>{settled=true});
  await sleep(10_000);
  assert.equal(settled,false,'The actual wait loop returned a stationary thinking heading');
  await evaluate({expression:`document.querySelector('[data-content-search-unit-key="new:2:assistant"] [data-markdown-text-style]').textContent='Partial report that has stopped changing but is not complete'`});
  await sleep(9_000);
  assert.equal(settled,false,'A mid-answer pause was mistaken for completion');
  await evaluate({expression:`document.querySelector('[data-content-search-unit-key="new:2:assistant"] [data-markdown-text-style]').textContent='Final report'; document.querySelector('#actions').innerHTML=${JSON.stringify(actions)}`});
  const answer = await pending;
  assert.equal(answer.text,'Final report','A preamble was returned instead of the final answer');

  // CDP 探测失败是未知状态，不是“没有生成活动”。
  const stopExpression = buildStopButtonVisibilityExpressionForTest();
  const unknownStop = {evaluate:args=>{
    if(args.expression===stopExpression) throw new Error('stop probe unavailable');
    return evaluate(args);
  },terminateExecution:()=>client.Runtime.terminateExecution()};
  await assert.rejects(waitForAssistantResponse(unknownStop,1500,()=>{},2),/timeout|deadline/i);

  await setBody('<main><article data-testid="conversation-turn-0"><div data-message-author-role="assistant" data-message-id="legacy"><div class="markdown">Legacy final</div></div>'+actions+'</article></main>');
  snapshot=await readAssistantSnapshot({evaluate},0);
  const legacyProof=await evaluate({expression:buildCompletionVisibilityExpressionForTest(snapshot,0)});
  assert.equal(legacyProof.result.value,true,'Legacy current-turn completion was lost');
  await evaluate({expression:`document.querySelector('button').remove(); document.querySelector('.markdown').textContent='Done'`});
  const doneText=await evaluate({expression:buildCompletionVisibilityExpressionForTest(snapshot,0)});
  assert.equal(doneText.result.value,false,'The word Done was accepted as completion evidence');

  // 有正文但没有完成证据必须超时，不能在截止时间回传候选文本。
  await setBody(prefix+current('Unconfirmed candidate')+'</main>');
  const started=Date.now();
  await assert.rejects(waitForAssistantResponse({evaluate,terminateExecution:()=>client.Runtime.terminateExecution()},1500,()=>{},2),/timeout|deadline/i);
  assert.ok(Date.now()-started < 3500,'Capture restarted its timeout budget');

  // Observer 在接近截止时失败，恢复轮询只能使用剩余预算。
  const failureStart=Date.now();
  const observerFailure = {evaluate:async args=>{
    if(args.awaitPromise) {await sleep(1000);throw new Error('observer disconnected');}
    return evaluate(args);
  },terminateExecution:()=>client.Runtime.terminateExecution()};
  await assert.rejects(waitForAssistantResponse(observerFailure,1500,()=>{},2),/observer disconnected/);
  assert.ok(Date.now()-failureStart<2400,'Observer recovery received a fresh full timeout');
  console.log('Native answer wait passed: long heading, stalled generation, final capture, timeout, recovery deadline');
} finally {
  if(client) await client.close();
  if(chrome) await chrome.kill();
  rmSync(profile,{recursive:true,force:true});
}
