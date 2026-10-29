const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function setup() {
  const context = { clearTimeout, setTimeout, Event: class { constructor(type) { this.type = type; } } };
  vm.runInNewContext(fs.readFileSync('priv/static/assets/console_completion.js', 'utf8'), context);
  const surface = () => ({ addEventListener() {}, removeEventListener() {} });
  const events = [];
  const form = { requestSubmit() { events.push('submit'); } };
  const input = { ...surface(), value: '', selectionStart: 0, selectionEnd: 0, style: {}, scrollHeight: 30, form,
    focus() {}, setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }, dispatchEvent() {} };
  const transcript = { scrollTop: 0, clientHeight: 300, scrollHeight: 300 };
  const el = { ...surface(), dataset: { busy: 'false', commandRevision: '0', history: '["X = 21.","X * 2."]' },
    querySelector: (selector) => selector === 'textarea' ? input : transcript };
  context.document = { activeElement: input };
  const hook = { ...context.BeamReplConsole, el, pushEvent: (name) => events.push(name) };
  hook.mounted();
  const key = (key, props = {}) => {
    const e = { key, target: input, preventDefault() { this.defaultPrevented = true; }, ...props };
    hook.onKey(e);
    return e;
  };
  return { hook, input, events, key };
}

test('Enter submits once, Shift+Enter adds a line, and completion keeps priority', () => {
  const e = setup();
  e.input.value = '1 + 1.';
  assert.equal(e.key('Enter', { shiftKey: true }).defaultPrevented, undefined);
  e.key('Enter', { defaultPrevented: true });
  assert.deepEqual(e.events, []);
  e.key('Enter');
  e.key('Enter');
  assert.deepEqual(e.events, ['submit']);
});

test('history recalls commands and restores an unsent draft without stealing multiline arrows', () => {
  const e = setup();
  e.input.value = 'draft';
  e.input.setSelectionRange(5, 5);
  e.key('ArrowUp');
  assert.equal(e.input.value, 'X * 2.');
  e.key('ArrowUp');
  assert.equal(e.input.value, 'X = 21.');
  e.key('ArrowDown');
  e.key('ArrowDown');
  assert.equal(e.input.value, 'draft');
  e.input.value = 'first\nsecond';
  e.input.setSelectionRange(12, 12);
  assert.equal(e.key('ArrowUp').defaultPrevented, undefined);
});

test('Ctrl+C interrupts but preserves copy, Ctrl+L clears, and IME input does not submit', () => {
  const e = setup();
  e.key('Enter', { isComposing: true });
  e.input.setSelectionRange(0, 2);
  assert.equal(e.key('c', { ctrlKey: true }).defaultPrevented, undefined);
  e.input.setSelectionRange(0, 0);
  e.key('c', { ctrlKey: true });
  e.key('l', { ctrlKey: true });
  assert.deepEqual(e.events, ['interrupt', 'clear']);
});
