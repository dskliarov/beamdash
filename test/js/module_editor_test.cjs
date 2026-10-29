const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const script = fs.readFileSync('priv/static/assets/module_editor.js', 'utf8');

function setup(storage = new Map()) {
  const events = [];
  const input = { value: 'original', dispatchEvent: (event) => events.push(event.type), form: { requestSubmit() { events.push('submit'); } } };
  const host = {};
  const classes = new Set();
  let api;
  const context = {
    Event: class { constructor(type) { this.type = type; } },
    localStorage: { getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value) },
    ResizeObserver: class { constructor(fn) { context.resize = fn; } observe() {} disconnect() { context.disconnected = true; } },
    BeamCodeMirror: { createEditor(_, options) {
      api = { value: options.doc, language: options.language, options,
        getValue() { return this.value; },
        setValue(value) { this.value = value; }, setLanguage(value) { this.language = value; },
        requestMeasure() {}, destroy() { this.destroyed = true; },
        type(value) { this.value = value; options.onChange(value); } };
      return api;
    } }
  };
  vm.runInNewContext(script, context);
  const hook = { ...context.BeamModuleEditor, el: {
    dataset: { language: 'elixir', revision: '1' }, style: {},
    classList: { add: (name) => classes.add(name), remove: (name) => classes.delete(name) },
    querySelector: (selector) => selector === 'textarea' ? input : host,
  } };
  hook.mounted();
  return { hook, input, host, api, context, classes, events };
}

test('edits update the form, while stale server echoes cannot replace newer typing', () => {
  const e = setup();
  assert.ok(e.classes.has('is-codemirror'));
  e.api.type('newest draft');
  assert.equal(e.input.value, 'newest draft');
  assert.deepEqual(e.events, ['input']);
  e.input.value = 'old server echo';
  e.hook.updated();
  assert.equal(e.api.value, 'newest draft');
  assert.equal(e.input.value, 'newest draft');
  e.api.options.onSubmit();
  assert.equal(e.events.at(-1), 'submit');
});

test('clear/discard revisions replace the document and language changes reconfigure it', () => {
  const e = setup();
  e.api.type('draft');
  e.input.value = '';
  e.hook.el.dataset.revision = '2';
  e.hook.updated();
  assert.equal(e.api.value, '');
  e.input.value = 'original';
  e.hook.el.dataset.revision = '3';
  e.hook.el.dataset.language = 'erlang';
  e.hook.updated();
  assert.equal(e.api.value, 'original');
  assert.equal(e.api.language, 'erlang');
  assert.equal(e.events.length, 1);
});

test('resized height survives patches and remounts, and the editor is destroyed', () => {
  const storage = new Map();
  const e = setup(storage);
  e.hook.el.style.height = '720px';
  e.context.resize();
  e.hook.beforeUpdate();
  e.hook.el.style.height = '';
  e.hook.updated();
  assert.equal(e.hook.el.style.height, '720px');
  e.hook.destroyed();
  assert.ok(e.api.destroyed);
  assert.ok(e.context.disconnected);
  assert.equal(setup(storage).hook.el.style.height, '720px');
});
