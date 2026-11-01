const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function setup() {
  const listeners = {};
  const buttons = {};
  for (const name of ['logs-scroll-top', 'logs-scroll-bottom']) {
    buttons[name] = {addEventListener(_type, fn) { this.click = fn; }, removeEventListener() {}};
  }
  const table = {top: 100, bottom: 1500, getBoundingClientRect() { return {top: this.top, bottom: this.bottom}; }};
  const window = {innerHeight: 800, scrollY: 0, calls: [],
    scrollTo(_x, y) { this.calls.push(y); },
    addEventListener(type, fn) { listeners[type] = fn; }, removeEventListener() {},
    requestAnimationFrame(fn) { fn(); return 1; }, cancelAnimationFrame() {}};
  const document = {getElementById(id) { return buttons[id]; }};
  const context = {window, document};
  vm.runInNewContext(fs.readFileSync('priv/static/assets/logs_scroll.js', 'utf8'), context);
  const hook = {...context.window.BeamLogsScroll, el: {closest() { return table; }}};
  hook.mounted();
  return {hook, table, window, buttons, listeners};
}

test('bottom button follows appended logs, top button stops following', () => {
  const {hook, table, window, buttons} = setup();
  buttons['logs-scroll-bottom'].click();
  assert.equal(window.calls.at(-1), 700);
  hook.beforeUpdate();
  table.bottom = 1700;
  hook.updated();
  assert.equal(window.calls.at(-1), 900);
  buttons['logs-scroll-top'].click();
  const count = window.calls.length;
  hook.beforeUpdate();
  table.bottom = 1800;
  hook.updated();
  assert.equal(window.calls.length, count);
});

test('scrolling away pauses following until the user returns to the bottom', () => {
  const {hook, table, window, buttons, listeners} = setup();
  buttons['logs-scroll-bottom'].click();
  table.bottom = 1300;
  listeners.scroll();
  hook.beforeUpdate();
  table.bottom = 1500;
  hook.updated();
  assert.equal(window.calls.length, 1);
  table.bottom = 800;
  listeners.scroll();
  hook.beforeUpdate();
  table.bottom = 1000;
  hook.updated();
  assert.equal(window.calls.length, 2);
});
