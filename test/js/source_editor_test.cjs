const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const script = fs.readFileSync('priv/static/assets/source_editor.js', 'utf8');

function editor(value = 'defmodule Demo do\nend', language = 'elixir', storage = new Map()) {
  const events = {};
  const input = { value, style: {}, scrollTop: 0, scrollLeft: 0,
    addEventListener: (event, fn) => { events[event] = fn; },
    removeEventListener: (event) => { delete events[event]; } };
  const code = { innerHTML: '', textContent: '' };
  const pre = { scrollTop: 0, scrollLeft: 0 };
  const classes = new Set();
  const calls = [];
  const context = { hljs: { highlight: (text, options) => { calls.push({text, ...options}); return { value: '<span class="hljs-keyword">code</span>' }; } } };
  context.localStorage = { getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value) };
  context.ResizeObserver = class {
    constructor(fn) { context.resize = fn; }
    observe() {}
    disconnect() { context.disconnected = true; }
  };
  vm.runInNewContext(script, context);
  const hook = { ...context.BeamSourceEditor, el: {
    dataset: { language },
    classList: { add: (name) => classes.add(name), remove: (name) => classes.delete(name) },
    querySelector: (selector) => ({ textarea: input, code, pre })[selector],
  } };
  hook.mounted();
  return { hook, input, code, pre, classes, calls, events, context };
}

test('highlights the exact editable source and language without changing the value', () => {
  const e = editor();
  assert.equal(e.calls[0].language, 'elixir');
  assert.equal(e.calls[0].text, e.input.value + '\n');
  assert.equal(e.input.value, 'defmodule Demo do\nend');
  assert.ok(e.classes.has('is-highlighted'));
  e.input.value = '-module(demo).';
  e.hook.el.dataset.language = 'erlang';
  e.events.input();
  assert.equal(e.calls.at(-1).language, 'erlang');
  assert.equal(e.calls.at(-1).text, '-module(demo).\n');
});

test('keeps scrolling synchronized and reacts to server updates', () => {
  const e = editor();
  e.input.scrollTop = 120; e.input.scrollLeft = 40;
  e.events.scroll();
  assert.equal(e.pre.scrollTop, 120); assert.equal(e.pre.scrollLeft, 40);
  e.input.value = 'new source';
  e.hook.updated();
  assert.equal(e.calls.at(-1).text, 'new source\n');
  e.hook.destroyed();
  assert.deepEqual(Object.keys(e.events), []);
});

test('keeps ordinary textarea text visible for large sources and highlighter failures', () => {
  const e = editor();
  e.input.value = 'x'.repeat(500001);
  e.events.input();
  assert.ok(!e.classes.has('is-highlighted'));
  e.input.value = 'short';
  e.context.hljs.highlight = () => { throw new Error('failed'); };
  e.events.input();
  assert.ok(!e.classes.has('is-highlighted'));
});

test('uses the bundled Elixir and Erlang grammars and escapes source HTML', () => {
  const e = editor();
  vm.runInNewContext(fs.readFileSync('priv/static/assets/vendor/highlight/highlight.min.js', 'utf8'), e.context);
  for (const language of ['elixir', 'erlang']) {
    vm.runInNewContext(fs.readFileSync(`priv/static/assets/vendor/highlight/${language}.min.js`, 'utf8'), e.context);
  }
  e.input.value = 'defmodule Demo do\n def value, do: "<script>"\nend';
  e.events.input();
  assert.match(e.code.innerHTML, /hljs-keyword/);
  assert.ok(!e.code.innerHTML.includes('<script>'));
  e.input.value = '-module(demo).\nvalue() -> ok.';
  e.hook.el.dataset.language = 'erlang';
  e.hook.updated();
  assert.match(e.code.innerHTML, /hljs-/);
});


test('keeps the resized height through patches, module switches, and cleanup', () => {
  const storage = new Map();
  const e = editor('source', 'elixir', storage);
  e.input.style.height = '720px';
  e.context.resize();
  e.hook.beforeUpdate();
  e.input.style.height = '';
  e.hook.updated();
  assert.equal(e.input.style.height, '720px');
  e.hook.destroyed();
  assert.ok(e.context.disconnected);
  const next = editor('different module', 'erlang', storage);
  assert.equal(next.input.style.height, '720px');
});
