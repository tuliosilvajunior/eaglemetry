# capy_ui

Shared v2 design system for the car app and the companion app.

See `DESIGN.md` for tokens, components, and rules.

## Tests

Component tests live here: `packages/capy_ui/test/` — run them with:

```bash
(cd packages/capy_ui && flutter test)
```

Gallery harness tests (`gallery_catalog`, `efficiency_gallery`) and tests that
need one app-core import (`app_theme_catalog`, `compass_tape`,
`energy_buckets`, `smoothness_gallery`, `tilt_gauge`) stay in the host app's
`test/` so the package does not depend on app code. Gallery pages are demo
fixtures only — package tests use minimal local fixtures and never import
`package:capy_ui/gallery/*`.
