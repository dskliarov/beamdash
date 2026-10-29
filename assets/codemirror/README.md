# Vendored Modules editor

The Modules tab uses CodeMirror 6 with `codemirror-lang-elixir` and the Erlang
stream language from `@codemirror/legacy-modes`. Package versions and transitive
dependencies are pinned in `package-lock.json`.

The browser loads the checked-in bundle from
`priv/static/assets/vendor/codemirror/editor.js`. No Node.js build or CDN is
needed to run Beamdash.

To rebuild or update the bundle, from this directory:

```sh
npm ci
npm run build
npm test
```

`build.mjs` also generates the bundled package versions and license notices.
Commit those files together with the bundle and lockfile. `editor.test.mjs`
instantiates the bundled CodeMirror in a DOM and checks actual editing,
programmatic replacement and language reconfiguration.

`priv/static/assets/module_editor.js` is the LiveView hook. It synchronizes the
form textarea, applies explicit server document revisions, and preserves the
resized height. The ignored CodeMirror host protects its selection and DOM from
ordinary LiveView patches. Server typing echoes never replace newer local input.
