# Changelog — Shentu

## [Unreleased]

### Changed
- The file checkboxes follow Finder's Kind menu: Archive, Document, Image, Movie, Music, PDF, Presentation, Text, in two columns. Hovering one shows its extensions. They're defined in `ShentuCore/Kinds.swift` by UTType conformance. Code, scripts and `.key`/`.ts` are never included (`kindsMatchFinder`).

### Removed
- Code carried over from Menshen that Shentu never runs: learning runs, config-based enforce, app swapping, the app library and access summaries (`Activity`, `Library`, `Summary`, `Swap`, and `Learn`/`Enforce.run` in `Modes`). `Enforce.runRestricted` is the only launch path.
- The rest of Menshen's learned-rule machinery: saved configs and rules (`Config`), rule learning (`Generalizer`), file categories (`Categories`), and the config compiler in `SBPLCompiler`. The Restricted profile now renders from a small internal rule type, with the same output as before.

## [0.1.0] — 2026-10-31

### Added
- Drop a Mac app on the window or the Dock icon. A pop-up offers network on or off, file kinds it can open in home and on drives (media, images, documents), and keeping its settings (off by default). It then runs confined, with writes only to a temp folder for this run, deleted afterwards, and no other programs.
- Runs list with blocked count, Stop, and Show Log. Choices are remembered per app.
- Self-contained: the sandboxing library is `Sources/ShentuSandbox`. Nothing outside this folder is needed.
- `scripts/build-app.sh` (no Xcode). Icon from `icon.jpg` via `scripts/make-icon.swift`.
- Kernel tests (`LaunchTests`) with a dummy app and a real disk image: a control and a mutation for every option, plus the real launch path (TMPDIR set, folder deleted, mutation-checked against ShentuSandbox).
