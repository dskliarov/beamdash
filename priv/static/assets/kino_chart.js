// Vega is loaded only when a notebook contains a chart.
(() => {
  let libraries;
  function loadLibraries() {
    if (!libraries) {
      const paths = ['vega.min.js', 'vega-lite.min.js', 'vega-embed.min.js'];
      libraries = paths.reduce((previous, path) => previous.then(() => new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = '/assets/vendor/vega/' + path;
        script.onload = resolve;
        script.onerror = () => reject(new Error('Unable to load chart renderer.'));
        document.head.appendChild(script);
      })), Promise.resolve()).catch(error => { libraries = null; throw error; });
    }
    return libraries;
  }

  globalThis.BeamKinoChart = {
    mounted() {
      this.pendingEvents = [];
      this.eventChain = Promise.resolve();
      this.handleEvent('kino-chart-update', update => {
        if (update.id !== this.el.dataset.chartId || (update.cell_id && update.cell_id !== this.el.dataset.cellId)) return;
        if (!this.view) this.pendingEvents.push(update);
        else this.enqueueEvent(update);
      });
      this.renderChart();
    },
    enqueueEvent(update) {
      this.eventChain = this.eventChain.then(async () => {
        if (!this.view) return;
        const payload = update.payload;
        if (update.event === 'push') {
          const name = payload.dataset || 'source_0';
          const current = this.view.data(name);
          const changes = globalThis.vega.changeset();
          if (payload.window === 0) changes.remove(current);
          else if (payload.window != null) {
            const inserted = payload.data.slice(-payload.window);
            const keep = Math.max(payload.window - inserted.length, 0);
            changes.remove(keep === 0 ? current : current.slice(0, -keep)).insert(inserted);
          } else changes.insert(payload.data);
          this.view.change(name, changes);
        } else if (update.event === 'set_param') this.view.signal(payload.name, payload.value);
        await this.view.runAsync();
      }).catch(error => { this.el.textContent = 'Unable to update chart: ' + error.message; });
    },
    updated() { if (this.renderedSpec !== this.el.dataset.spec) this.renderChart(); },
    destroyed() { this.generation++; if (this.view) this.view.finalize(); },
    async renderChart() {
      const generation = this.generation = (this.generation || 0) + 1;
      const spec = this.el.dataset.spec;
      this.renderedSpec = spec;
      if (this.view) { this.view.finalize(); this.view = null; }
      try {
        const parsed = JSON.parse(spec);
        const datasets = JSON.parse(this.el.dataset.datasets || "[]");
        if (this.el.dataset.chartId && !parsed.data) parsed.data = {values: []};
        await loadLibraries();
        if (generation !== this.generation) return;
        // Chart specifications may come from a remote node. Never fetch their URLs.
        const loader = globalThis.vega.loader();
        loader.load = () => Promise.reject(new Error('External chart data is disabled.'));
        loader.sanitize = () => Promise.reject(new Error('External chart resources are disabled.'));
        const result = await globalThis.vegaEmbed(this.el, parsed, {mode: 'vega-lite', actions: false, loader});
        if (generation !== this.generation) result.view.finalize();
        else {
          this.view = result.view;
          for (const [name, data] of datasets) this.view.data(name || 'source_0', data);
          if (datasets.length) await this.view.runAsync();
          const pending = this.pendingEvents.splice(0);
          for (const update of pending) this.enqueueEvent(update);
        }
      } catch (error) {
        if (generation === this.generation) this.el.textContent = 'Unable to render chart: ' + error.message;
      }
    }
  };
})();
