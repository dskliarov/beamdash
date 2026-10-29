globalThis.BeamNotebookFiles = {
  mounted() {
    this.editRevision = 0;
    this.savedRevision = 0;
    this.saveRevision = null;
    this.replacementRevision = null;
    this.localDirty = () => this.editRevision !== this.savedRevision;
    this.onInput = (e) => {
      if (e.target.matches('[name="source"], [name="title"], [name="include_outputs"]')) this.editRevision++;
    };
    this.handleEvent('notebook-saved', () => {
      if (this.saveRevision !== null) this.savedRevision = this.saveRevision;
      this.saveRevision = null;
    });
    this.handleEvent('notebook-replaced', () => {
      if (this.replacementRevision !== null) this.savedRevision = this.replacementRevision;
      this.replacementRevision = null;
    });
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
      if (this.el.dataset.dirty !== 'true' && !this.localDirty()) return;
      e.preventDefault();
      e.returnValue = '';
    };
    this.confirmAction = (e) => {
      const target = e.target.closest('[data-notebook-confirm], [phx-click="new_notebook"], [phx-click="open_notebook"]');
      const fallback = target && this.localDirty() && target.matches('[phx-click="new_notebook"], [phx-click="open_notebook"]') ? 'Discard unsaved notebook changes?' : null;
      if (target && this.el.contains(target)) {
        if ((target.dataset.notebookConfirm || fallback) && !window.confirm(target.dataset.notebookConfirm || fallback)) {
          e.preventDefault();
          e.stopImmediatePropagation();
        } else if (target.matches('[phx-click="new_notebook"], [phx-click="open_notebook"]')) {
          this.replacementRevision = this.editRevision;
        }
      }
    };
    this.confirmNavigation = (e) => {
      const link = e.target.closest('a[data-phx-link]');
      if ((this.el.dataset.dirty === 'true' || this.localDirty()) && link && !window.confirm('Leave this page and discard unsaved notebook changes?')) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    };
    this.confirmSubmit = (e) => {
      if (e.target.matches('.notebook-save')) this.saveRevision = this.editRevision;
      const importing = e.target.matches('[phx-submit="import_notebook"]');
      const message = e.target.dataset.notebookConfirm || (importing && this.localDirty() ? 'Discard unsaved notebook changes?' : null);
      if (message && !window.confirm(message)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      } else if (importing) this.replacementRevision = this.editRevision;
    };
    window.addEventListener('beforeunload', this.beforeUnload);
    this.el.addEventListener('click', this.confirmAction, true);
    this.el.addEventListener('submit', this.confirmSubmit, true);
    this.el.addEventListener('input', this.onInput, true);
    document.addEventListener('click', this.confirmNavigation, true);
  },
  destroyed() {
    window.removeEventListener('beforeunload', this.beforeUnload);
    this.el.removeEventListener('click', this.confirmAction, true);
    this.el.removeEventListener('submit', this.confirmSubmit, true);
    this.el.removeEventListener('input', this.onInput, true);
    document.removeEventListener('click', this.confirmNavigation, true);
  },
};
