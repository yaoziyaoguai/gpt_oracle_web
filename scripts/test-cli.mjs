import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [runtimeRoot, wrapper] = process.argv.slice(2);
assert.ok(runtimeRoot && wrapper, 'Usage: node scripts/test-cli.mjs RUNTIME_ROOT WRAPPER');
const sessionRoot = mkdtempSync(path.join(tmpdir(), 'oracle-web-cli-test-'));
try {
  // 使用真正的 CLI 解析器；fake Oracle 无法发现 wrapper 传入了不被支持的参数。
  for (const args of [[], ['--browser-thinking-time', 'extra-high']]) {
    const result = spawnSync(wrapper, [
      '--dry-run', 'summary', '-p', 'Harmless CLI contract probe.', ...args,
    ], {
      encoding: 'utf8',
      timeout: 20_000,
      env: {
        ...process.env,
        ORACLE_WEB_ORACLE_BIN: path.join(runtimeRoot, 'dist/bin/oracle-cli.js'),
        ORACLE_WEB_SESSION_DIR: sessionRoot,
      },
    });
    assert.equal(result.status, 0, `${args.join(' ') || 'default max'}: ${result.stderr || result.error}`);
    assert.match(result.stdout, /\[preview\].*browser mode/);
  }
  const { buildBrowserConfig } = await import(pathToFileURL(path.join(runtimeRoot, 'dist/src/cli/browserConfig.js')));
  for (const level of ['max', 'extra-high']) {
    const config = await buildBrowserConfig({
      model: 'gpt-5.6-sol', browserModelStrategy: 'current', browserThinkingTime: level,
    });
    assert.equal(config.thinkingTime, level, 'Requested effort was discarded before browser execution');
  }
  console.log('Real CLI effort contract passed');
} finally {
  rmSync(sessionRoot, { recursive: true, force: true });
}
