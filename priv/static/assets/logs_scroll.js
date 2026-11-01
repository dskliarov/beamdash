// Follow the end of the Logs table only while the user is at its bottom.
window.BeamLogsScroll = {
  mounted() {
    this.table = this.el.closest('.logs-table');
    this.topButton = document.getElementById('logs-scroll-top');
    this.bottomButton = document.getElementById('logs-scroll-bottom');
    this.following = false;
    this.frame = null;

    this.toTop = () => {
      this.following = false;
      if (this.table) window.scrollTo(0, Math.max(0, window.scrollY + this.table.getBoundingClientRect().top - 50));
    };
    this.toBottom = () => {
      if (!this.table) return;
      this.following = true;
      window.scrollTo(0, Math.max(0, window.scrollY + this.table.getBoundingClientRect().bottom - window.innerHeight));
    };
    this.onScroll = () => {
      if (!this.table) return;
      const bottom = this.table.getBoundingClientRect().bottom;
      this.following = bottom >= 0 && bottom <= window.innerHeight + 32;
    };
    this.topButton?.addEventListener('click', this.toTop);
    this.bottomButton?.addEventListener('click', this.toBottom);
    window.addEventListener('scroll', this.onScroll, {passive: true});
    this.onScroll();
    if (window.MutationObserver) {
      this.observer = new window.MutationObserver(() => this.scheduleFollow());
      this.observer.observe(this.el, {childList: true, subtree: true, characterData: true});
    }
  },
  beforeUpdate() {
    this.followAfterUpdate = this.following;
  },
  updated() {
    if (!this.followAfterUpdate) return;
    this.scheduleFollow();
  },
  scheduleFollow() {
    if (!this.following) return;
    if (this.frame != null) window.cancelAnimationFrame(this.frame);
    this.frame = window.requestAnimationFrame(() => {
      this.frame = null;
      if (this.following) this.toBottom();
    });
  },
  destroyed() {
    if (this.frame != null) window.cancelAnimationFrame(this.frame);
    this.observer?.disconnect();
    this.topButton?.removeEventListener('click', this.toTop);
    this.bottomButton?.removeEventListener('click', this.toBottom);
    window.removeEventListener('scroll', this.onScroll);
  }
};
