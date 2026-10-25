// Phoenix and LiveView are loaded as globals from the deps (see the root layout).

// Drag handle that resizes something by setting a CSS variable on <html>.
// The size lives outside the LiveView-rendered DOM, so updates from the
// server never reset it, and it is remembered (localStorage) across reloads.
//
//   data-var        CSS variable to set, e.g. "--panel-w"
//   data-axis       "x": width of data-target, measured from its right edge
//                   (the handle sits on its left); "y": height of data-target
//                   from its top (the handle sits below it)
//   data-grow="up"  ("y" only) the handle sits on top and the height is
//                   measured from the bottom edge (a panel docked at the
//                   bottom of the window)
//   data-grow="right" ("x" only) the handle sits on the right and the width
//                   is measured from the left edge (a sidebar)
//   data-target     selector of the element being resized
//   data-min / data-max   bounds in px
//   data-container  ("x" only) selector of the layout; data-keep px of it
//                   are left for the rest
//
// Arrow keys resize in 24 px steps; double-click or Home goes back to
// the default size.
const Resizer = {
  mounted() {
    const el = this.el;
    const d = el.dataset;
    const root = document.documentElement;
    const key = "beamdash:" + d.var;
    const store = (v) => {
      try {
        v == null ? localStorage.removeItem(key) : localStorage.setItem(key, String(v));
      } catch (_e) {}
    };
    const target = () => document.querySelector(d.target);

    const bounds = () => {
      let max = Number(d.max);
      if (d.axis === "x") {
        const layout = document.querySelector(d.container);
        if (layout) max = Math.min(max, layout.clientWidth - Number(d.keep || 0));
      } else {
        max = Math.min(max, Math.round(window.innerHeight * 0.85));
      }
      return [Number(d.min), Math.max(Number(d.min), max)];
    };

    const set = (px, save) => {
      const [min, max] = bounds();
      const v = Math.round(Math.max(min, Math.min(max, px)));
      root.style.setProperty(d.var, v + "px");
      el.setAttribute("aria-valuenow", v);
      el.setAttribute("aria-valuemin", min);
      el.setAttribute("aria-valuemax", max);
      if (save) store(v);
    };

    const size = () => {
      const t = target();
      if (!t) return 0;
      const r = t.getBoundingClientRect();
      return d.axis === "x" ? r.width : r.height;
    };

    const reset = () => {
      root.style.removeProperty(d.var);
      store(null);
      el.setAttribute("aria-valuenow", Math.round(size()));
    };

    let saved = null;
    try {
      saved = localStorage.getItem(key);
    } catch (_e) {}
    if (saved) set(Number(saved), false);
    else el.setAttribute("aria-valuenow", Math.round(size()));

    el.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const t = target();
      if (!t) return;
      e.preventDefault();
      const r = t.getBoundingClientRect();
      el.setPointerCapture(e.pointerId);
      el.classList.add("dragging");
      document.body.classList.add("resizing-" + d.axis);

      const move = (ev) =>
        set(
          d.axis === "x"
            ? d.grow === "right"
              ? ev.clientX - r.left
              : r.right - ev.clientX
            : d.grow === "up"
              ? r.bottom - ev.clientY
              : ev.clientY - r.top,
          false,
        );
      const up = (ev) => {
        el.releasePointerCapture(ev.pointerId);
        el.removeEventListener("pointermove", move);
        el.removeEventListener("pointerup", up);
        el.removeEventListener("pointercancel", up);
        el.classList.remove("dragging");
        document.body.classList.remove("resizing-" + d.axis);
        set(size(), true);
      };
      el.addEventListener("pointermove", move);
      el.addEventListener("pointerup", up);
      el.addEventListener("pointercancel", up);
    });

    el.addEventListener("dblclick", reset);

    el.addEventListener("keydown", (e) => {
      // the process panel grows to the left, a sidebar to the right; a log
      // grows downwards, the dock up
      const up = d.grow === "up";
      const right = d.grow === "right";
      const grow = d.axis === "x" ? (right ? "ArrowRight" : "ArrowLeft") : up ? "ArrowUp" : "ArrowDown";
      const shrink = d.axis === "x" ? (right ? "ArrowLeft" : "ArrowRight") : up ? "ArrowDown" : "ArrowUp";
      if (e.key === grow || e.key === shrink) {
        e.preventDefault();
        set(size() + (e.key === grow ? 24 : -24), true);
      } else if (e.key === "Home") {
        e.preventDefault();
        reset();
      }
    });
  },
};

// Keeps --dock-actual on <html> at the dock's real height, so the page can
// leave room for it at the bottom (the dock's height follows its panels).
const DockSpacer = {
  mounted() {
    const root = document.documentElement;
    const set = () => root.style.setProperty("--dock-actual", this.el.offsetHeight + "px");
    this.observer = new ResizeObserver(set);
    this.observer.observe(this.el);
    set();
  },
  destroyed() {
    this.observer.disconnect();
    document.documentElement.style.removeProperty("--dock-actual");
  },
};

// The tab bar: tabs that do not fit move into "More ▾" (never the current
// one), and keyboard shortcuts: g then a tab's key, ? lists them.
const NavOverflow = {
  mounted() {
    this.fit = () => this.layout();
    this.resize = new ResizeObserver(this.fit);
    this.resize.observe(this.el);
    this.layout();

    this.pending = null;
    this.onKey = (e) => this.key(e);
    window.addEventListener("keydown", this.onKey);
    this.onHelp = (e) => {
      if (e.target.closest("[data-shortcuts-open]")) this.help();
    };
    document.addEventListener("click", this.onHelp);
  },
  updated() { this.layout(); },
  destroyed() {
    this.resize.disconnect();
    window.removeEventListener("keydown", this.onKey);
    document.removeEventListener("click", this.onHelp);
  },

  layout() {
    const nav = this.el;
    const tabs = [...nav.querySelectorAll(":scope > a.tab")];
    const seps = [...nav.querySelectorAll(":scope > .tab-sep")];
    const more = nav.querySelector(".tabs-more");
    const menu = more.querySelector(".tabs-more-menu");
    tabs.forEach((t) => t.classList.remove("overflowed"));
    seps.forEach((s) => s.classList.remove("overflowed"));
    more.hidden = true;
    menu.replaceChildren();
    if (nav.scrollWidth <= nav.clientWidth) return;

    more.hidden = false;
    // hide from the end, keeping the current tab, until the rest fits
    const hidden = [];
    for (const t of [...tabs].reverse()) {
      if (nav.scrollWidth <= nav.clientWidth) break;
      if (t.classList.contains("active")) continue;
      t.classList.add("overflowed");
      hidden.unshift(t);
    }
    // a divider with nothing visible after it goes too
    seps.forEach((s) => {
      let n = s.nextElementSibling, shown = false;
      while (n && n.classList.contains("tab")) {
        if (!n.classList.contains("overflowed")) shown = true;
        n = n.nextElementSibling;
      }
      if (!shown) s.classList.add("overflowed");
    });
    for (const t of hidden) {
      const item = t.cloneNode(true);
      item.classList.remove("overflowed");
      item.setAttribute("role", "menuitem");
      item.addEventListener("click", () => { more.open = false; });
      menu.append(item);
    }
  },

  key(e) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    const t = e.target;
    if (t.closest("input, textarea, select, [contenteditable]")) return;
    const dialog = document.getElementById("shortcuts");
    if (e.key === "?") { e.preventDefault(); this.help(); return; }
    if (this.pending) {
      clearTimeout(this.pending);
      this.pending = null;
      const link = document.querySelector(`a.tab[data-key="${CSS.escape(e.key)}"]`);
      if (link) {
        e.preventDefault();
        if (dialog && dialog.open) dialog.close();
        link.click();
      }
      return;
    }
    if (e.key === "g") this.pending = setTimeout(() => { this.pending = null; }, 1500);
  },

  help() {
    const dialog = document.getElementById("shortcuts");
    if (!dialog) return;
    dialog.open ? dialog.close() : dialog.showModal();
  },
};

// Namespace input backed by a <datalist> of the cluster's namespaces:
// picking a suggestion lists that namespace's pods straight away, typing
// waits for Enter or "List pods" (any name is accepted).
const NamespacePick = {
  mounted() {
    this.el.addEventListener("input", (e) => {
      // a pick arrives as a replacement or as a plain input event without an inputType
      if (e.inputType && e.inputType !== "insertReplacementText") return;
      const options = this.el.list ? Array.from(this.el.list.options) : [];
      if (options.some((o) => o.value === this.el.value)) this.el.form.requestSubmit();
    });
  },
};

// The Logs tab: copies or downloads log lines the page pushes as
// "logs-export" ({name, text, mode}); the text never goes through the DOM.
const LogExport = {
  mounted() {
    this.handleEvent("logs-export", ({ name, text, lines, mode }) => {
      if (mode === "copy") {
        const done = (ok, reason) => this.pushEvent("export_done", { ok, lines, reason });
        // navigator.clipboard is only there in a secure context (HTTPS or localhost)
        if (!navigator.clipboard) return done(false, "no_clipboard");
        navigator.clipboard.writeText(text).then(() => done(true), () => done(false));
        return;
      }
      const url = URL.createObjectURL(new Blob([text + "\n"], { type: "text/plain" }));
      const a = document.createElement("a");
      a.href = url;
      a.download = name;
      document.body.append(a);
      a.click();
      a.remove();
      // revoked once the click's download has started
      setTimeout(() => URL.revokeObjectURL(url), 0);
    });
  },
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { Resizer, DockSpacer, NavOverflow, NamespacePick, LogExport },
});
liveSocket.connect();
window.liveSocket = liveSocket;
