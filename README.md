# Shentu

Drop a Mac app on Shentu, choose what it can reach for this run, and it opens in a sandbox.

| Option in the pop-up | What it means |
|---|---|
| Internet and network | Off: no internet or local-network connections. |
| Files it can open: Archive, Document, Image, Movie, Music, PDF, Presentation, Text | Finder's Kind names. In your home folder and on drives (`/Volumes`), it can open only files of these kinds; hover a checkbox for its extensions. It can see file and folder names. System files and the app itself are always readable. Finder's other kinds aren't offered: Application and Executable are programs, folders are always listable, and Other would mean everything. |
| Keep its settings between runs | Off (the default): no access to its own ~/Library data, and no saved settings, so it starts fresh. |
| *(always)* | It saves files only to a temporary folder made for this run, which is deleted when it quits. |
| *(always)* | It can't start other programs or open links. A built-in sanity set (secrets, other apps' data, persistence) is always blocked. |

Your choices are remembered per app. What the app was blocked from is logged; Show Log opens it.

**Expect some apps to complain.** Mac apps ignore TMPDIR (NSTemporaryDirectory always returns the shared per-user folder), so an app's normal temp and cache writes are blocked.

## How it works

Everything Shentu needs is in this folder. `Sources/ShentuSandbox` builds the Seatbelt profiles, launches the app and keeps the deny log. `Sources/ShentuCore` maps the pop-up to a `RestrictedSandbox` (`Sources/ShentuCore/Launch.swift`) and calls `Enforce.runRestricted`.

Shentu's data lives in `~/Library/Application Support/Shentu` (profiles, remembered choices) and `~/Library/Logs/Shentu`.

## Build (no Xcode needed)

```bash
./scripts/build-app.sh
```

This builds `build/Shentu.app`. Nothing outside this folder is needed.

The icon is `assets/AppIcon.png`, made once from `icon.jpg` by `scripts/make-icon.swift`, which removes the checkerboard painted into the JPEG.

## Tests

```bash
swift test
```

`LaunchTests` are kernel tests: a self-built dummy app (never one of yours) runs under the profile Shentu builds, using a real disk image mounted under /Volumes. Each must-fail step has a must-succeed control in the same profile, and a mutation (the option flipped, or its rule cut) that makes it succeed. `launchMakesAndRemovesTheTempFolder` goes through the real launch path.
