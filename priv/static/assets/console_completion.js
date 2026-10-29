// Metadata-only completion for the remote expression console.
globalThis.BeamConsoleCompletion = {
  contextAt(value, caret, language) {
    const before = value.slice(0, caret);
    const pattern = language === 'elixir'
      ? /[:A-Za-z_][A-Za-z0-9_.:!?]*$/
      : /(?:'[^'\n]+'|[a-z][A-Za-z0-9_@]*)(?::[A-Za-z0-9_@]*)?$/;
    const token = (before.match(pattern) || [''])[0];
    return { token, start: caret - token.length, end: caret };
  },
  replacement(value, range, insert) {
    return { value: value.slice(0, range.start) + insert + value.slice(range.end), caret: range.start + insert.length };
  },
  mounted() {
    this.input = this.el.querySelector('textarea');
    // LiveView may detach the input before destroyed(), clearing input.form.
    this.form = this.input.form;
    this.list = this.el.querySelector('[role=listbox]');
    this.toggle = this.el.querySelector('input[type=checkbox]');
    this.sequence = 0;
    this.items = [];
    this.active = -1;
    this.schedule = () => {
      this.close();
      clearTimeout(this.timer);
      if (this.toggle.checked && !this.input.readOnly) this.timer = setTimeout(() => this.requestCompletion(), 150);
    };
    this.onKey = (e) => this.key(e);
    this.onBlur = () => { clearTimeout(this.timer); this.close(); };
    this.onToggle = () => { this.onBlur(); if (this.toggle.checked) this.requestCompletion(); };
    this.onPick = (e) => {
      const item = e.target.closest('[data-completion-index]');
      if (!item) return;
      e.preventDefault();
      this.choose(Number(item.dataset.completionIndex));
    };
    this.input.addEventListener('input', this.schedule);
    this.input.addEventListener('click', this.schedule);
    this.input.addEventListener('keydown', this.onKey);
    this.input.addEventListener('blur', this.onBlur);
    this.toggle.addEventListener('change', this.onToggle);
    this.list.addEventListener('mousedown', this.onPick);
    this.form.addEventListener('submit', this.onBlur);
    this.close();
  },
  signature() {
    return JSON.stringify([this.input.value, this.input.selectionStart, this.el.dataset.language, this.el.dataset.node]);
  },
  requestCompletion(manual = false) {
    if (!this.toggle.checked || this.input.readOnly || this.dead) return this.close();
    const range = this.contextAt(this.input.value, this.input.selectionStart, this.el.dataset.language);
    if (!range.token && !manual) return this.close();
    const signature = this.signature();
    const sequence = ++this.sequence;
    this.requestSignature = signature;
    this.pushEvent('complete', { token: range.token, cell_id: this.el.dataset.cellId || null }, (reply) => {
      if (this.dead || sequence !== this.sequence || signature !== this.signature() || !this.toggle.checked || this.input.readOnly) return;
      this.range = range;
      this.requestSignature = signature;
      this.items = reply.items || [];
      this.active = this.items.length ? 0 : -1;
      this.render();
    });
  },
  render() {
    this.list.replaceChildren(...this.items.map((item, index) => {
      const option = document.createElement('button');
      option.type = 'button';
      option.setAttribute('role', 'option');
      option.setAttribute('tabindex', '-1');
      option.setAttribute('aria-selected', String(index === this.active));
      option.id = this.list.id + '-' + index;
      option.dataset.completionIndex = String(index);
      option.textContent = item.label;
      return option;
    }));
    this.list.hidden = this.items.length === 0;
    this.input.setAttribute('aria-expanded', String(!this.list.hidden));
    if (this.active >= 0) this.input.setAttribute('aria-activedescendant', this.list.id + '-' + this.active);
    else this.input.removeAttribute('aria-activedescendant');
  },
  close() {
    ++this.sequence;
    this.items = [];
    this.active = -1;
    this.list.hidden = true;
    this.input.setAttribute('aria-expanded', 'false');
    this.input.removeAttribute('aria-activedescendant');
  },
  choose(index) {
    if (!this.items[index] || this.requestSignature !== this.signature()) return this.close();
    const replacement = this.replacement(this.input.value, this.range, this.items[index].insert);
    this.input.value = replacement.value;
    this.input.setSelectionRange(replacement.caret, replacement.caret);
    this.close();
    this.input.focus();
    this.input.dispatchEvent(new Event('input', { bubbles: true }));
  },
  key(e) {
    if (e.isComposing) return;
    if (e.ctrlKey && (e.key === ' ' || e.code === 'Space')) {
      e.preventDefault(); clearTimeout(this.timer); this.requestCompletion(true); return;
    }
    if (e.key === 'Escape') { clearTimeout(this.timer); this.close(); return; }
    if (this.list.hidden || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      this.active = (this.active + (e.key === 'ArrowDown' ? 1 : -1) + this.items.length) % this.items.length;
      this.render();
      this.list.children[this.active].scrollIntoView({ block: 'nearest' });
    } else if (e.key === 'Tab' || e.key === 'Enter') {
      e.preventDefault(); this.choose(this.active);
    }
  },
  updated() {
    if (this.requestSignature !== this.signature() || this.input.readOnly) this.close();
    else this.input.setAttribute('aria-expanded', String(!this.list.hidden));
  },
  destroyed() {
    this.dead = true;
    ++this.sequence;
    clearTimeout(this.timer);
    this.input.removeEventListener('input', this.schedule);
    this.input.removeEventListener('click', this.schedule);
    this.input.removeEventListener('keydown', this.onKey);
    this.input.removeEventListener('blur', this.onBlur);
    this.toggle.removeEventListener('change', this.onToggle);
    this.list.removeEventListener('mousedown', this.onPick);
    this.form.removeEventListener('submit', this.onBlur);
  },
};

// Terminal-style controls for the shell; completion handles its keys first.
globalThis.BeamReplConsole = {
  mounted() {
    this.input = this.el.querySelector('textarea');
    this.form = this.input.form;
    this.transcript = this.el.querySelector('[role=log]');
    this.revision = this.el.dataset.commandRevision;
    this.readHistory();
    this.onKey = (e) => this.key(e);
    this.onInput = () => {
      this.resize();
      if (!this.recalling) this.position = this.history.length;
    };
    this.el.addEventListener('keydown', this.onKey);
    this.input.addEventListener('input', this.onInput);
    this.resize();
    this.input.focus();
    this.transcript.scrollTop = this.transcript.scrollHeight;
  },
  readHistory() {
    const encoded = this.el.dataset.history;
    if (encoded === this.encodedHistory) return;
    this.encodedHistory = encoded;
    try { this.history = JSON.parse(encoded); } catch (_) { this.history = []; }
    this.position = this.history.length;
  },
  resize() {
    this.input.style.height = 'auto';
    this.input.style.height = Math.min(260, Math.max(30, this.input.scrollHeight)) + 'px';
  },
  key(e) {
    if (e.target !== this.input || e.defaultPrevented || e.isComposing) return;
    if (e.ctrlKey && e.key.toLowerCase() === 'c') {
      if (this.input.selectionStart !== this.input.selectionEnd) return;
      e.preventDefault();
      this.pushEvent('interrupt', {});
      return;
    }
    if (e.ctrlKey && e.key.toLowerCase() === 'l') {
      e.preventDefault();
      this.pushEvent('clear', {});
      return;
    }
    if (this.el.dataset.busy === 'true' || this.submitting) return;
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey) {
      e.preventDefault();
      if (this.input.value.trim() === '') return;
      this.submitting = true;
      this.form.requestSubmit();
      return;
    }
    if (e.ctrlKey || e.metaKey || e.altKey || e.shiftKey || this.input.selectionStart !== this.input.selectionEnd) return;
    const up = e.key === 'ArrowUp';
    const down = e.key === 'ArrowDown';
    if (!up && !down) return;
    if (up && this.input.value.slice(0, this.input.selectionStart).includes('\n')) return;
    if (down && this.input.value.slice(this.input.selectionStart).includes('\n')) return;
    const next = Math.max(0, Math.min(this.history.length, this.position + (up ? -1 : 1)));
    if (next === this.position) return;
    e.preventDefault();
    if (this.position === this.history.length) this.draft = this.input.value;
    this.position = next;
    this.input.value = next === this.history.length ? (this.draft || '') : this.history[next];
    this.input.setSelectionRange(this.input.value.length, this.input.value.length);
    this.recalling = true;
    this.input.dispatchEvent(new Event('input', { bubbles: true }));
    this.recalling = false;
    this.resize();
  },
  beforeUpdate() {
    this.followOutput = this.transcript.scrollHeight - this.transcript.scrollTop - this.transcript.clientHeight < 60;
    this.hadFocus = document.activeElement === this.input;
  },
  updated() {
    this.readHistory();
    this.submitting = this.el.dataset.busy === 'true';
    if (this.revision !== this.el.dataset.commandRevision) {
      this.revision = this.el.dataset.commandRevision;
      this.input.value = this.el.dataset.command;
      this.position = this.history.length;
      this.input.setSelectionRange(this.input.value.length, this.input.value.length);
    }
    this.resize();
    if (this.followOutput) this.transcript.scrollTop = this.transcript.scrollHeight;
    if (this.hadFocus) this.input.focus();
  },
  destroyed() {
    this.el.removeEventListener('keydown', this.onKey);
    this.input.removeEventListener('input', this.onInput);
  },
};
