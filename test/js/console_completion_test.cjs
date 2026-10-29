const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = { clearTimeout, setTimeout, Event: class { constructor(type) { this.type = type; } } };
vm.runInNewContext(fs.readFileSync('priv/static/assets/console_completion.js', 'utf8'), context);
const completion = context.BeamConsoleCompletion;

test('finds the module/function token at the caret in multiline expressions', () => {
  const code = 'x = 1\nEnum.ma + 2';
  const found = completion.contextAt(code, 13, 'elixir');
  assert.equal(found.token, 'Enum.ma');
  assert.equal(found.start, 6);
  assert.equal(completion.contextAt('lists:ma', 8, 'erlang').token, 'lists:ma');
  assert.equal(completion.contextAt(':lists.ma', 9, 'elixir').token, ':lists.ma');
});

test('inserts a function at the caret without losing surrounding code', () => {
  const code = 'x = Enum.ma + rest';
  const range = completion.contextAt(code, 11, 'elixir');
  const result = completion.replacement(code, range, 'Enum.map(');
  assert.equal(result.value, 'x = Enum.map( + rest');
  assert.equal(result.caret, 13);
});

test('does not apply stale completions after the expression changes', () => {
  let callback;
  let rendered = false;
  const hook = { ...completion,
    el: { dataset: { language: 'elixir', node: 'remote' } },
    input: { value: 'Enum.ma', selectionStart: 7, readOnly: false },
    toggle: { checked: true }, sequence: 0,
    pushEvent: (_, __, cb) => { callback = cb; },
    close() {}, render() { rendered = true; }
  };
  hook.requestCompletion();
  hook.input.value = 'Map.';
  callback({ items: [{ label: 'Enum.map/2', insert: 'Enum.map(' }] });
  assert.equal(rendered, false);
});

test('Tab inserts the selected suggestion and notifies the form; Escape dismisses', () => {
  const hook = { ...completion,
    el: { dataset: { language: 'elixir', node: 'remote' } },
    input: { value: 'Enum.ma', selectionStart: 7,
      setAttribute() {}, removeAttribute() {}, focus() {},
      setSelectionRange(start) { this.selectionStart = start; },
      dispatchEvent(event) { this.event = event.type; }
    },
    list: { hidden: false }, sequence: 0, active: 0,
    items: [{ label: 'Enum.map/2', insert: 'Enum.map(' }],
    range: { start: 0, end: 7, token: 'Enum.ma' }
  };
  hook.requestSignature = hook.signature();
  let prevented = false;
  hook.key({ key: 'Tab', preventDefault() { prevented = true; } });
  assert.equal(hook.input.value, 'Enum.map(');
  assert.equal(hook.input.event, 'input');
  assert.equal(prevented, true);
  hook.key({ key: 'Escape' });
  assert.equal(hook.list.hidden, true);
});

test('cleans up autocomplete after its form is detached during tab navigation', () => {
  const surface = () => ({
    listeners: new Map(),
    addEventListener(event, handler) { this.listeners.set(event, handler); },
    removeEventListener(event, handler) {
      if (this.listeners.get(event) === handler) this.listeners.delete(event);
    },
    setAttribute() {}, removeAttribute() {}
  });
  const form = surface();
  let attached = true;
  const input = { ...surface(), get form() { return attached ? form : null; } };
  const list = surface();
  const toggle = surface();
  const elements = { textarea: input, '[role=listbox]': list, 'input[type=checkbox]': toggle };
  const hook = { ...completion, el: { querySelector: (selector) => elements[selector] } };
  hook.mounted();
  assert.equal(form.listeners.size, 1);

  // Native textarea.form becomes null when LiveView removes the old view.
  attached = false;
  hook.destroyed();
  for (const element of [form, input, list, toggle]) assert.equal(element.listeners.size, 0);
  assert.equal(hook.dead, true);
});
