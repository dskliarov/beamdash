// Keep editing in a real textarea; Highlight.js paints a non-interactive copy.
globalThis.BeamSourceEditor = {
  mounted() {
    this.input = this.el.querySelector('textarea');
    this.code = this.el.querySelector('code');
    this.preview = this.el.querySelector('pre');
    this.heightKey = this.el.dataset.heightKey || 'beamdash:module-source-height';
    this.rememberSize = () => {
      const height = this.input.style.height;
      if (!/^\d+(\.\d+)?px$/.test(height) || parseFloat(height) < 120 || parseFloat(height) > 10000) return;
      this.savedHeight = height;
      try { globalThis.localStorage.setItem(this.heightKey, height); } catch (_) {}
    };
    try {
      const height = globalThis.localStorage.getItem(this.heightKey);
      if (/^\d+(\.\d+)?px$/.test(height) && parseFloat(height) >= 120 && parseFloat(height) <= 10000) {
        this.input.style.height = height;
        this.savedHeight = height;
      }
    } catch (_) {}
    if (globalThis.ResizeObserver) {
      this.resizeObserver = new ResizeObserver(this.rememberSize);
      this.resizeObserver.observe(this.input);
    }

    this.paint = () => {
      const source = this.input.value;
      const language = this.el.dataset.language;
      this.el.classList.remove('is-highlighted');
      if (!globalThis.hljs || source.length > 500000) return;
      try {
        // The extra newline keeps the last editable line aligned and scrollable.
        this.code.innerHTML = globalThis.hljs.highlight(source + '\n', { language }).value;
        this.el.classList.add('is-highlighted');
        this.syncScroll();
      } catch (_) {
        // Leave the native textarea visible if highlighting is unavailable.
      }
    };
    this.syncScroll = () => {
      this.preview.scrollTop = this.input.scrollTop;
      this.preview.scrollLeft = this.input.scrollLeft;
    };
    this.input.addEventListener('input', this.paint);
    this.input.addEventListener('scroll', this.syncScroll);
    this.paint();
  },
  beforeUpdate() { this.rememberSize(); },
  updated() {
    if (this.savedHeight) this.input.style.height = this.savedHeight;
    this.paint();
  },
  destroyed() {
    if (this.resizeObserver) this.resizeObserver.disconnect();
    this.input.removeEventListener('input', this.paint);
    this.input.removeEventListener('scroll', this.syncScroll);
  },
};
