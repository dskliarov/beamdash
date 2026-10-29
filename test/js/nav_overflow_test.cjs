const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('priv/static/assets/app.js', 'utf8');
const start = source.indexOf('const NavOverflow = {');
const end = source.indexOf('\n// The namespace field:', start);
const context = {};
vm.runInNewContext(source.slice(start, end).replace('const NavOverflow =', 'globalThis.NavOverflow ='), context);

function tab(name, special = false, active = false) {
  const classes = new Set(active ? ['tab', 'active'] : ['tab']);
  return { name, dataset: {overflowLast: special ? 'true' : undefined},
    classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x) },
    cloneNode() { const copy = tab(name); copy.setAttribute = () => {}; copy.addEventListener = () => {}; return copy; } };
}
function setup(active = '') {
  const tabs = [tab('System', false, active === 'System'), tab('Modules', true, active === 'Modules'), tab('Console', true, active === 'Console'), tab('Trace', false, active === 'Trace'), tab('Profile')];
  const menu = {items: [], replaceChildren() {this.items = [];}, append(t) {this.items.push(t.name);}};
  const more = { open: false, querySelector: () => menu, set hidden(value) {this._hidden = value; if (value) this.open = false;}, get hidden() {return this._hidden;} };
  const nav = {clientWidth: 3, get scrollWidth() {return tabs.filter(t => !t.classList.contains('overflowed')).length + (more.hidden ? 0 : 1);},
    querySelectorAll: s => s === ':scope > a.tab' ? tabs : [], querySelector: () => more};
  return {hook: {...context.NavOverflow, el: nav}, more, menu, tabs};
}
test('keeps the More menu open during layout and lists Modules and Console last', () => {
  const e = setup();
  e.hook.layout();
  assert.deepEqual(e.menu.items, ['Profile', 'Modules', 'Console']);
  e.more.open = true;
  e.hook.layout();
  assert.equal(e.more.open, true);
  assert.deepEqual(e.menu.items, ['Profile', 'Modules', 'Console']);
});
test('keeps the active Modules tab visible', () => {
  const e = setup('Modules');
  e.hook.layout();
  assert.equal(e.tabs[1].classList.contains('overflowed'), false);
  assert.equal(e.menu.items.at(-1), 'Console');
});
