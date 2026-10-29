globalThis.BeamNotebookFiles = {
  mounted() {
    this.handleEvent('notebook-download', ({ name, text }) => {
      const url = URL.createObjectURL(new Blob([text], { type: 'text/markdown;charset=utf-8' }));
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 0);
    });
    this.beforeUnload = (e) => {
      if (this.el.dataset.dirty !== 'true') return;
      e.preventDefault();
      e.returnValue = '';
    };
    this.confirmAction = (e) => {
      const target = e.target.closest('[data-notebook-confirm]');
      if (target && this.el.contains(target) && !window.confirm(target.dataset.notebookConfirm)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    };
    this.confirmNavigation = (e) => {
      const link = e.target.closest('a[data-phx-link]');
      if (this.el.dataset.dirty === 'true' && link && !window.confirm('Leave this page and discard unsaved notebook changes?')) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    };
    this.confirmSubmit = (e) => {
      const message = e.target.dataset.notebookConfirm;
      if (message && !window.confirm(message)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    };
    window.addEventListener('beforeunload', this.beforeUnload);
    this.el.addEventListener('click', this.confirmAction, true);
    this.el.addEventListener('submit', this.confirmSubmit, true);
    document.addEventListener('click', this.confirmNavigation, true);
  },
  destroyed() {
    window.removeEventListener('beforeunload', this.beforeUnload);
    this.el.removeEventListener('click', this.confirmAction, true);
    this.el.removeEventListener('submit', this.confirmSubmit, true);
    document.removeEventListener('click', this.confirmNavigation, true);
  },
};
