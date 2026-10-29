const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function setup() {
  const events = {}, handlers = {}, downloads = [];
  const surface = (name) => ({
    addEventListener: (event, fn) => { events[name + ':' + event] = fn; },
    removeEventListener: (event) => { delete events[name + ':' + event]; }
  });
  const context = {
    window: { ...surface('window'), confirm: () => false },
    document: { ...surface('document'), body: { append() {} },
      createElement: () => ({ click() { downloads.push(this.download); }, remove() {} }) },
    URL: { createObjectURL(blob) { context.blob = blob; return 'blob:test'; }, revokeObjectURL() {} },
    Blob: class { constructor(parts) { this.parts = parts; } }, setTimeout: (fn) => fn()
  };
  vm.runInNewContext(fs.readFileSync('priv/static/assets/notebook_files.js', 'utf8'), context);
  const hook = { ...context.BeamNotebookFiles, el: { ...surface('element'), dataset: { dirty: 'true' }, contains: () => true }, handleEvent: (name, fn) => { handlers[name] = fn; } };
  hook.mounted();
  return { hook, context, events, handlers, downloads };
}

test('downloads the exact LiveMarkdown source without changing newlines', () => {
  const e = setup();
  e.handlers['notebook-download']({name: 'node.livemd', text: '# Node\n'});
  assert.deepEqual(e.downloads, ['node.livemd']);
  assert.equal(e.context.blob.parts.join(''), '# Node\n');
});

test('guards unsaved navigation and cleans up listeners', () => {
  const e = setup();
  let prevented = false;
  e.events['window:beforeunload']({ preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  e.hook.el.dataset.dirty = 'false';
  prevented = false;
  e.events['window:beforeunload']({ preventDefault() { prevented = true; } });
  assert.equal(prevented, false);
  e.hook.destroyed();
  assert.equal(Object.keys(e.events).length, 0);
});
