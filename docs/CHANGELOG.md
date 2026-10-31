# Changelog — Shentu

## [0.1.0] — 2026-10-31

### Added
- Drop a Mac app on the window or the Dock icon. A pop-up offers network on or off, file kinds it can open in home and on drives (media, images, documents), and keeping its settings (off by default). It then runs confined, with writes only to a temp folder for this run, deleted afterwards, and no other programs.
- Runs list with blocked count, Stop, and Show Log. Choices are remembered per app.
- Built on MenshenCore (`../menshen`, ADR-010 there); `MENSHEN_PATH` selects another checkout.
- `scripts/build-app.sh` (no Xcode). Icon from `icon.jpg` via `scripts/make-icon.swift`.
- Kernel tests (`LaunchTests`) with a dummy app and a real disk image: a control and a mutation for every option, plus the real launch path (TMPDIR set, folder deleted, mutation-checked against MenshenCore).
