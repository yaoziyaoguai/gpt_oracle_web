import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

const runtimeRoot = process.argv[2];
const { uploadAttachmentFile } = await import(pathToFileURL(path.join(runtimeRoot, 'dist/src/browser/actions/attachments.js')));
class Input {
  constructor(accept) { this.attrs = { accept }; this.files = []; }
  getAttribute(name) { return this.attrs[name] ?? null; }
  hasAttribute(name) { return name === 'multiple'; }
  setAttribute(name, value) { this.attrs[name] = value; }
  getBoundingClientRect() { return { width: 0, height: 0 }; }
}
const inputs = [new Input('image/*,video/*'), new Input('image/*'), new Input('')];
const root = { querySelectorAll: selector => selector === 'input[type="file"]' ? inputs : [] };
const document = { ...root, body: root, querySelector: () => null };
let selection;
const stop = new Error('candidate captured');
try {
  await uploadAttachmentFile({
    runtime: { evaluate: async ({ expression }) => {
      if (expression.includes('data-oracle-upload-candidate')) {
        selection = vm.runInNewContext(expression, { document, HTMLElement: Input, HTMLInputElement: Input });
        throw stop;
      }
      return { result: { value: false } };
    } },
    dom: { getDocument: async () => ({ root: { nodeId: 1 } }) },
  }, { path: '/tmp/harmless-probe.txt' }, () => {});
} catch (error) { if (error !== stop) throw error; }
assert.equal(selection?.order?.[0], 2, 'Text attachment must select the unrestricted file input, not photos/videos');
console.log('Attachment input DOM regression passed');
