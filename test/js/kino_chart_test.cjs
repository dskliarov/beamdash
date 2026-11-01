const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('loads local chart renderer, blocks external data and cleans up', async () => {
  const scripts = [], calls = [], finalized = [];
  const context = {
    document: {
      createElement() { return {}; },
      head: { appendChild(script) { scripts.push(script.src); queueMicrotask(script.onload); } }
    },
    vega: { loader: () => ({}) },
    vegaEmbed: async (el, spec, options) => {
      calls.push({ spec, options });
      return { view: { finalize() { finalized.push(spec.mark); } } };
    },
    Promise, Error, JSON
  };
  vm.runInNewContext(fs.readFileSync('priv/static/assets/kino_chart.js', 'utf8'), context);
  const hook = { ...context.BeamKinoChart, el: { dataset: { spec: '{"mark":"bar"}' } }, handleEvent() {} };
  hook.mounted();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(scripts.length, 3);
  assert.ok(scripts.every(path => path.startsWith('/assets/vendor/vega/')));
  assert.equal(calls[0].spec.mark, 'bar');
  await assert.rejects(calls[0].options.loader.load('https://example.org/data'), /disabled/);
  await assert.rejects(calls[0].options.loader.sanitize('https://example.org/image'), /disabled/);
  hook.el.dataset.spec = '{"mark":"line"}';
  hook.updated();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(finalized, ['bar']);
  assert.equal(calls[1].spec.mark, 'line');
  hook.destroyed();
  assert.deepEqual(finalized, ['bar', 'line']);
});

test('queues live chart events until the renderer is ready and applies them in order', async () => {
  const handlers = {}, calls = [], loaders = [];
  const view = {
    data(name, value) { if (value) { calls.push(['data', name, value]); return this; } return [1, 2]; },
    change(name, changes) { calls.push(['change', name, changes.ops]); return this; },
    signal(name, value) { calls.push(['signal', name, value]); return this; },
    async runAsync() { calls.push(['run']); }, finalize() {}
  };
  const context = {
    document: { createElement() { return {}; }, head: { appendChild(script) { loaders.push(script); } } },
    vega: { loader: () => ({}), changeset: () => ({ ops: [], remove(x) { this.ops.push(['remove', x]); return this; }, insert(x) { this.ops.push(['insert', x]); return this; } }) },
    vegaEmbed: async () => ({view}), Promise, Error, JSON
  };
  vm.runInNewContext(fs.readFileSync('priv/static/assets/kino_chart.js', 'utf8'), context);
  const hook = { ...context.BeamKinoChart, el: { dataset: { spec: '{"mark":"line"}', chartId: 'chart-1', cellId: 'cell-1', datasets: '[[null,[{"x":1}]]]' } }, handleEvent(name, callback) { handlers[name] = callback; } };
  hook.mounted();
  handlers['kino-chart-update']({id: 'chart-1', cell_id: 'other-cell', event: 'set_param', payload: {name: 'wrong', value: 0}});
  handlers['kino-chart-update']({id: 'other', event: 'set_param', payload: {name: 'p', value: 0}});
  handlers['kino-chart-update']({id: 'chart-1', event: 'push', payload: {dataset: null, data: [{x: 3}], window: 2}});
  handlers['kino-chart-update']({id: 'chart-1', event: 'set_param', payload: {name: 'p', value: 7}});
  for (let i = 0; i < 3; i++) { await new Promise(resolve => setImmediate(resolve)); loaders[i].onload(); }
  await new Promise(resolve => setImmediate(resolve));
  await hook.eventChain;
  assert.equal(calls[0][0], 'data');
  assert.equal(calls[0][1], 'source_0');
  assert.ok(calls.some(call => call[0] === 'change' && call[1] === 'source_0'));
  assert.ok(calls.some(call => call[0] === 'signal' && call[1] === 'p' && call[2] === 7));
  assert.ok(!calls.some(call => call[0] === 'signal' && call[1] === 'wrong'));
});
