# Shentu

Drop a Mac app on Shentu, choose what it can reach for this run, and it opens in a sandbox.

| Option in the pop-up | What it means |
|---|---|
| Internet and network | Off: no internet or local-network connections. |
| Files it can open: Media, Images, Documents | In your home folder and on drives (`/Volumes`), it can open only files of these kinds. It can see file and folder names. System files and the app itself are always readable. |
| Keep its settings between runs | Off (the default): no access to its own ~/Library data, and no saved settings, so it starts fresh. |
| *(always)* | It saves files only to a temporary folder made for this run, which is deleted when it quits. |
| *(always)* | It can't start other programs or open links. Menshen's sanity set (secrets, other apps' data, persistence) is always blocked. |

Your choices are remembered per app. What the app was blocked from is logged; Show Log opens it.

**Expect some apps to complain.** Mac apps ignore TMPDIR (NSTemporaryDirectory always returns the shared per-user folder), so an app's normal temp and cache writes are blocked.

## How it works

Shentu has no sandbox logic of its own. Profiles, the launch and the deny log come from **MenshenCore** (`../menshen`, the Restricted Sandbox; see Menshen's ADR-010), so the two apps can't drift. Shentu maps the pop-up to a `RestrictedSandbox` (`Sources/ShentuCore/Launch.swift`) and calls `Enforce.runRestricted`.

Shentu's data lives apart from Menshen's: `~/Library/Application Support/Shentu` (profiles, remembered choices) and `~/Library/Logs/Shentu`.

## Build (no Xcode needed)

```bash
./scripts/build-app.sh
```

This builds `build/Shentu.app` against `../menshen`. To build against another Menshen checkout (a worktree whose changes aren't merged yet), set `MENSHEN_PATH`:

```bash
MENSHEN_PATH=<another menshen checkout> ./scripts/build-app.sh
```

The icon is `assets/AppIcon.png`, made once from `icon.jpg` by `scripts/make-icon.swift`, which removes the checkerboard painted into the JPEG.

## Tests

```bash
swift test
```

`LaunchTests` are kernel tests: a self-built dummy app (never one of yours) runs under the profile Shentu builds, using a real disk image mounted under /Volumes. Each must-fail step has a must-succeed control in the same profile, and a mutation (the option flipped, or its rule cut) that makes it succeed. `launchMakesAndRemovesTheTempFolder` goes through the real launch path.
