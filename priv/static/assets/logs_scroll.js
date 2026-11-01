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
      this.jumpedToTop = true;
      if (this.table) this.table.scrollTop = 0;
    };
    this.toBottom = () => {
      if (!this.table) return;
      this.following = true;
      this.table.scrollTop = this.table.scrollHeight;
    };
    this.onScroll = () => {
      if (!this.table) return;
      const jumped = this.jumpedToTop;
      this.jumpedToTop = false;
      if (jumped && this.table.scrollTop === 0) return;
      this.following = this.table.scrollHeight - this.table.scrollTop - this.table.clientHeight <= 32;
    };
    this.topButton?.addEventListener('click', this.toTop);
    this.bottomButton?.addEventListener('click', this.toBottom);
    this.table?.addEventListener('scroll', this.onScroll, {passive: true});
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
    this.table?.removeEventListener('scroll', this.onScroll);
  }
};
