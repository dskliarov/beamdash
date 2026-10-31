const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('priv/static/assets/app.js', 'utf8');
const start = source.indexOf('const MemoryScroll = {');
const end = source.indexOf('\nconst csrfToken', start);
const window = {scrollX: 0, scrollY: 450, calls: [], scrollTo(x, y) { this.calls.push([x, y]); }};
const page = {contains: target => target.inside === true};
const document = {getElementById: () => page};
const context = {window, document};
vm.runInNewContext(source.slice(start, end).replace('const MemoryScroll =', 'globalThis.hook ='), context);
const patch = {inside: true, contains: () => false};

test('keeps the viewport when a memory update changes its position', () => {
  const hook = {...context.hook};
  hook.onPatchStart(patch);
  window.scrollY = 0;
  hook.onPatchEnd();
  assert.deepEqual(window.calls, [[0, 450]]);
});

test('does not scroll when the viewport did not move', () => {
  window.calls = [];
  window.scrollY = 800;
  const hook = {...context.hook};
  hook.onPatchStart(patch);
  hook.onPatchEnd();
  assert.deepEqual(window.calls, []);
});

test('does not alter scroll for unrelated page patches', () => {
  window.calls = [];
  const hook = {...context.hook};
  hook.onPatchStart({contains: () => false});
  window.scrollY = 0;
  hook.onPatchEnd();
  assert.deepEqual(window.calls, []);
});
