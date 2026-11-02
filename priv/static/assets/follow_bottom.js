// Keeps a scrollable element pinned to its bottom while the reader stays near it.
window.BeamFollow = {
  nearBottom(el) {
    return el.scrollHeight - el.scrollTop - el.clientHeight <= 60;
  },
  snapToBottom(el) {
    el.scrollTop = el.scrollHeight;
  }
};
