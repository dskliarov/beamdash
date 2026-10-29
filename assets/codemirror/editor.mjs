import { basicSetup } from 'codemirror';
import { EditorState, Compartment } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { indentWithTab } from '@codemirror/commands';
import { StreamLanguage, HighlightStyle, syntaxHighlighting, indentUnit } from '@codemirror/language';
import { erlang } from '@codemirror/legacy-modes/mode/erlang';
import { elixir } from 'codemirror-lang-elixir';
import { tags } from '@lezer/highlight';
import { autocompletion, completeAnyWord, completeFromList } from '@codemirror/autocomplete';

const theme = EditorView.theme({
  '&': { height: '100%', color: 'var(--fg)', backgroundColor: 'var(--bg)', fontSize: '12.5px' },
  '.cm-scroller': { overflow: 'auto', fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', lineHeight: '1.5' },
  '.cm-content': { padding: '8px 0', caretColor: 'var(--fg)' },
  '.cm-line': { padding: '0 12px' },
  '.cm-gutters': { color: 'var(--muted)', backgroundColor: 'var(--row-alt)', borderRight: '1px solid var(--line)' },
  '.cm-activeLine, .cm-activeLineGutter': { backgroundColor: 'var(--row-alt)' },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--fg)' },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: 'color-mix(in srgb, var(--accent) 25%, transparent)' },
  '.cm-panels, .cm-tooltip': { backgroundColor: 'var(--bg)', color: 'var(--fg)', borderColor: 'var(--line)' },
  '.cm-search input, .cm-search button': { color: 'var(--fg)', backgroundColor: 'var(--bg)' },
  '.cm-tooltip-autocomplete > ul > li[aria-selected]': { backgroundColor: 'var(--accent)', color: 'white' },
  '&.cm-focused': { outline: 'none' },
});
const colors = HighlightStyle.define([
  { tag: [tags.keyword, tags.operatorKeyword], color: 'var(--code-keyword)' },
  { tag: [tags.string, tags.regexp, tags.character], color: 'var(--code-string)' },
  { tag: [tags.number, tags.bool, tags.null, tags.meta], color: 'var(--code-number)' },
  { tag: tags.comment, color: 'var(--code-comment)', fontStyle: 'italic' },
  { tag: [tags.atom, tags.special(tags.string)], color: 'var(--code-atom)' },
  { tag: [tags.function(tags.variableName), tags.className, tags.definition(tags.variableName)], color: 'var(--code-title)' },
  { tag: [tags.variableName, tags.typeName, tags.propertyName], color: 'var(--code-builtin)' },
]);
const erlangMode = StreamLanguage.define(erlang);
const languageExtension = (language) => language === 'elixir' ? elixir() : erlangMode;
const keywordCompletions = {
  elixir: completeFromList('alias case cond def defdelegate defguard defimpl defmacro defmodule defp defprotocol defstruct do else end fn for if import quote raise receive require rescue try unless unquote use when with'.split(' ').map(label => ({ label, type: 'keyword' }))),
  erlang: completeFromList('after begin case catch cond end fun if let of receive try when'.split(' ').map(label => ({ label, type: 'keyword' }))),
};

export function createEditor(parent, { doc = '', language = 'erlang', onChange = () => {}, onSubmit = () => {}, complete = async () => [] } = {}) {
  const languageConfig = new Compartment();
  let currentLanguage = language;
  const state = (source) => EditorState.create({
    doc: source,
    extensions: [
      basicSetup, theme, syntaxHighlighting(colors), indentUnit.of('  '),
      autocompletion({ override: [completeAnyWord, (context) => keywordCompletions[currentLanguage](context), async (context) => {
        const pattern = currentLanguage === 'elixir'
          ? /[:A-Za-z_][A-Za-z0-9_.:!?]*$/
          : /(?:'[^'\n]+'|[a-z][A-Za-z0-9_@]*)(?::[A-Za-z0-9_@]*)?$/;
        const match = context.matchBefore(pattern);
        if (!match || !match.text) return null;
        const languageAtRequest = currentLanguage;
        let items;
        try { items = await complete(match.text, languageAtRequest); } catch (_) { return null; }
        if (context.aborted || languageAtRequest !== currentLanguage || !Array.isArray(items)) return null;
        return { from: match.from, to: match.to, options: items.filter((item) => typeof item.label === 'string' && typeof item.insert === 'string').map((item) => ({ label: item.label, apply: item.insert, type: 'function' })), filter: false };
      }] }),
      languageConfig.of(languageExtension(currentLanguage)),
      EditorView.contentAttributes.of({ 'aria-label': 'Module source code', spellcheck: 'false' }),
      keymap.of([{ key: 'Mod-Enter', run: () => { onSubmit(); return true; } }, indentWithTab]),
      EditorView.updateListener.of((update) => { if (update.docChanged) onChange(update.state.doc.toString()); }),
    ],
  });
  const view = new EditorView({ state: state(doc), parent });
  return {
    view,
    getValue: () => view.state.doc.toString(),
    setValue(source) { if (source !== view.state.doc.toString()) view.setState(state(source)); },
    setLanguage(next) {
      if (next === currentLanguage) return;
      currentLanguage = next;
      view.dispatch({ effects: languageConfig.reconfigure(languageExtension(next)) });
    },
    requestMeasure: () => view.requestMeasure(),
    destroy: () => view.destroy(),
  };
}
