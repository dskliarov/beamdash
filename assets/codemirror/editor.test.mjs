import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
const bundle = readFileSync(new URL('../../priv/static/assets/vendor/codemirror/editor.js', import.meta.url), 'utf8');

function setup(options) {
  const dom = new JSDOM('<div id="editor"></div>', { pretendToBeVisual: true, runScripts: 'outside-only' });
  dom.window.Range.prototype.getClientRects = () => [];
  dom.window.Range.prototype.getBoundingClientRect = () => new dom.window.DOMRect();
  dom.window.eval(bundle);
  const editor = dom.window.BeamCodeMirror.createEditor(dom.window.document.getElementById('editor'), options);
  return { dom, editor, close() { editor.destroy(); dom.window.close(); } };
}

test('bundled CodeMirror renders a real editor, line numbers, and emits edits', () => {
  const changes = [];
  const e = setup({ doc: 'defmodule Demo do\nend', language: 'elixir', onChange: (text) => changes.push(text) });
  try {
    assert.ok(e.dom.window.document.querySelector('.cm-editor .cm-content[contenteditable=true]'));
    assert.ok(e.dom.window.document.querySelector('.cm-lineNumbers'));
    assert.equal(e.editor.getValue(), 'defmodule Demo do\nend');
    e.editor.view.dispatch({ changes: { from: 0, to: e.editor.view.state.doc.length, insert: 'x = 42' } });
    assert.deepEqual(changes, ['x = 42']);
  } finally { e.close(); }
});

test('server replacements and language changes preserve form synchronization without edit loops', () => {
  const changes = [];
  const e = setup({ doc: 'original', language: 'elixir', onChange: (text) => changes.push(text) });
  try {
    e.editor.setValue('');
    assert.equal(e.editor.getValue(), '');
    e.editor.setValue('original');
    e.editor.setLanguage('erlang');
    e.editor.setValue('-module(demo).\nvalue() -> ok.');
    assert.equal(e.editor.getValue(), '-module(demo).\nvalue() -> ok.');
    assert.deepEqual(changes, []);
    e.editor.view.dispatch({ changes: { from: e.editor.view.state.doc.length, insert: '\n' } });
    assert.equal(changes.length, 1);
  } finally { e.close(); }
});

test('completion requests module and function metadata for both languages', async () => {
  const requests = [];
  const e = setup({ doc: 'Enum.ma', language: 'elixir', complete: async (token, language) => {
    requests.push([token, language]);
    return [{ label: 'Enum.map/2', insert: 'Enum.map(' }];
  } });
  try {
    e.editor.view.dispatch({ selection: { anchor: 7 } });
    e.editor.view.contentDOM.dispatchEvent(new e.dom.window.KeyboardEvent('keydown', { key: ' ', ctrlKey: true, bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 200));
    assert.deepEqual(requests[0], ['Enum.ma', 'elixir']);
    assert.match(e.dom.window.document.body.textContent, /Enum\.map\/2/);
    e.editor.setLanguage('erlang');
    e.editor.setValue('lists:ma');
    e.editor.view.dispatch({ selection: { anchor: 8 } });
    e.editor.view.contentDOM.dispatchEvent(new e.dom.window.KeyboardEvent('keydown', { key: ' ', ctrlKey: true, bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 200));
    assert.ok(requests.some(([token, language]) => token === 'lists:ma' && language === 'erlang'));
  } finally { e.close(); }
});
