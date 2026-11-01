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
  const table = {
    scrollTop: 0, scrollHeight: 1500, clientHeight: 500,
    addEventListener(type, fn) { listeners[type] = fn; }, removeEventListener() {},
    scrollTo({top}) { this.scrollTop = top; }
  };
  const window = {calls: [], scrollTo(...args) { this.calls.push(args); },
    requestAnimationFrame(fn) { fn(); return 1; }, cancelAnimationFrame() {}};
  const document = {getElementById(id) { return buttons[id]; }};
  const context = {window, document};
  vm.runInNewContext(fs.readFileSync('priv/static/assets/logs_scroll.js', 'utf8'), context);
  const hook = {...context.window.BeamLogsScroll, el: {closest() { return table; }}};
  hook.mounted();
  return {hook, table, window, buttons, listeners};
}

test('navigation scrolls only the log list and follows appended rows', () => {
  const {hook, table, window, buttons} = setup();
  buttons['logs-scroll-bottom'].click();
  assert.equal(table.scrollTop, 1500);
  hook.beforeUpdate();
  table.scrollHeight = 1700;
  hook.updated();
  assert.equal(table.scrollTop, 1700);
  buttons['logs-scroll-top'].click();
  assert.equal(table.scrollTop, 0);
  hook.beforeUpdate();
  table.scrollHeight = 1800;
  hook.updated();
  assert.equal(table.scrollTop, 0);
  assert.equal(window.calls.length, 0);
});

test('manual scrolling away pauses following until returning to the bottom', () => {
  const {hook, table, buttons, listeners} = setup();
  buttons['logs-scroll-bottom'].click();
  table.scrollTop = 100;
  listeners.scroll();
  hook.beforeUpdate();
  table.scrollHeight = 1800;
  hook.updated();
  assert.equal(table.scrollTop, 100);
  table.scrollTop = 1300;
  listeners.scroll();
  hook.beforeUpdate();
  table.scrollHeight = 2000;
  hook.updated();
  assert.equal(table.scrollTop, 2000);
});
