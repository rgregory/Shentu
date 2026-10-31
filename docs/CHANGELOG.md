# Changelog — Shentu

## [Unreleased]

### Changed
- The file checkboxes follow Finder's Kind menu: Archive, Document, Image, Movie, Music, PDF, Presentation, Text, in two columns. Hovering one shows its extensions. They're defined in `ShentuCore/Kinds.swift` by UTType conformance, so the vendored MenshenCore is untouched. Code, scripts and `.key`/`.ts` are never included (`kindsMatchFinder`).

## [0.1.0] — 2026-10-31

### Added
- Drop a Mac app on the window or the Dock icon. A pop-up offers network on or off, file kinds it can open in home and on drives (media, images, documents), and keeping its settings (off by default). It then runs confined, with writes only to a temp folder for this run, deleted afterwards, and no other programs.
- Runs list with blocked count, Stop, and Show Log. Choices are remembered per app.
- Standalone: MenshenCore (Menshen's sandboxing library, ADR-010 there) is copied unmodified into `Sources/MenshenCore`, with its source commit in `VENDORED.md`. Builds with nothing outside this folder.
- `scripts/build-app.sh` (no Xcode). Icon from `icon.jpg` via `scripts/make-icon.swift`.
- Kernel tests (`LaunchTests`) with a dummy app and a real disk image: a control and a mutation for every option, plus the real launch path (TMPDIR set, folder deleted, mutation-checked against MenshenCore).
