// The Modules editor owns its DOM. The textarea remains the form/fallback value.
globalThis.BeamModuleEditor = {
  mounted() {
    this.input = this.el.querySelector('textarea');
    this.host = this.el.querySelector('.codemirror-host');
    this.revision = this.el.dataset.revision;
    this.heightKey = 'beamdash:module-source-height';
    this.rememberSize = () => {
      const height = this.el.style.height;
      if (!/^\d+(\.\d+)?px$/.test(height) || parseFloat(height) < 120 || parseFloat(height) > 10000) return;
      this.savedHeight = height;
      try { globalThis.localStorage.setItem(this.heightKey, height); } catch (_) {}
    };
    try {
      const height = globalThis.localStorage.getItem(this.heightKey);
      if (/^\d+(\.\d+)?px$/.test(height) && parseFloat(height) >= 120 && parseFloat(height) <= 10000) {
        this.savedHeight = height;
        this.el.style.height = height;
      }
    } catch (_) {}
    if (globalThis.ResizeObserver) {
      this.resizeObserver = new ResizeObserver(() => {
        this.rememberSize();
        if (this.editor) this.editor.requestMeasure();
      });
      this.resizeObserver.observe(this.el);
    }
    if (!globalThis.BeamCodeMirror) return;
    this.editor = globalThis.BeamCodeMirror.createEditor(this.host, {
      doc: this.input.value,
      language: this.el.dataset.language,
      complete: (token, language) => new Promise((resolve) => {
        if (this.dead) return resolve([]);
        this.pushEvent('complete_editor', { token, language }, (reply) => resolve(this.dead ? [] : (reply.items || [])));
      }),
      onChange: (source) => {
        this.input.value = source;
        this.input.dispatchEvent(new Event('input', { bubbles: true }));
      },
      onSubmit: () => {
        this.input.value = this.editor.getValue();
        if (this.input.form) this.input.form.requestSubmit();
      },
    });
    this.el.classList.add('is-codemirror');
    this.editor.requestMeasure();
  },
  beforeUpdate() { this.rememberSize(); },
  updated() {
    if (this.savedHeight) this.el.style.height = this.savedHeight;
    if (!this.editor) return;
    if (this.revision !== this.el.dataset.revision) {
      this.editor.setValue(this.input.value);
      this.revision = this.el.dataset.revision;
    } else {
      // Typing echoes may arrive after a newer local edit. Never apply those.
      this.input.value = this.editor.getValue();
    }
    this.editor.setLanguage(this.el.dataset.language);
    this.el.classList.add('is-codemirror');
    this.editor.requestMeasure();
  },
  destroyed() {
    this.dead = true;
    if (this.resizeObserver) this.resizeObserver.disconnect();
    if (this.editor) this.editor.destroy();
  },
};
