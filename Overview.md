# Shentu

Drop a Mac app on Shentu, choose what it can reach for this run, and it opens in a seatbelt sandbox.

| Option in the pop-up | What it means |
|---|---|
| Internet and network | Off: no internet or local-network connections. |
| Files it can open: **By kind** | Archive, Document, Image, Movie, Music, PDF, Presentation, Text (Finder's Kind names), each Off, Read, or Read & Write. Every file of that kind in your home folder and on drives (`/Volumes`); hover a name for its extensions. Read & Write also lets it create, change, rename and delete files of that kind there, and nowhere else. Apps that save through a temporary file with another name (NSDocument's safe save) can't save them. It can see file and folder names. System files and the app itself are always readable. Code, scripts and Finder's other kinds (Application, Executable, Other) aren't offered. |
| Files it can open: **Only these** | Just the files and folders you pick, read-only (a folder includes everything inside it). Less access than a kind, which opens every matching file you have. |
| Output folder | Optional. One folder it can read, change and delete anything in, so its work survives the run. Must be inside your home folder or on a drive; never your whole home folder, a whole drive, ~/Library, or a protected place. Checked again at every launch. |
| Keep its settings between runs | Off (the default): no access to its own ~/Library data, and no saved settings, so it starts fresh. On: its folders in ~/Library, found by the name and bundle ID in its Info.plist. Those are the app's own claims, so only plain folder names are used, and the sanity set still wins: an app calling itself Slack doesn't get Slack's data (and the real Slack can't keep its settings in Shentu). |
| *(always)* | Any other file it saves goes to a temporary folder made for this run, which is deleted when it quits. |
| *(always)* | It can't start other programs or open links. A built-in sanity set (secrets, other apps' data, persistence) is always blocked. |
| *(always)* | Stop, or the app quitting, ends everything it started too. |

Your choices are remembered per app.

Each run shows where it is: Starting, Running, Quit, Quit with an error (the exit code), Crashed (the signal), Stopped, or Launch failed (why). If the system log dropped messages, the run says its logging was incomplete.

**Activity** opens what the app was blocked from: grouped into Files, Network, Programs and Services, counted, searchable by path, address, service or process, and exportable as CSV. The raw log (JSON lines) is a click away.

**Expect some apps to complain.** Mac apps ignore TMPDIR (NSTemporaryDirectory always returns the shared per-user folder), so an app's normal temp and cache writes are blocked.

## How it works

Everything Shentu needs is in this folder. `Sources/ShentuSandbox` builds the Seatbelt profiles, launches the app and keeps the deny log. `Sources/ShentuCore` maps the pop-up to a `RestrictedSandbox` (`Sources/ShentuCore/Launch.swift`) and calls `Enforce.runRestricted`.

Shentu keeps remembered choices in `~/Library/Application Support/Shentu`. Each run's profile (`.sb`) and log (`.jsonl`) go in `~/Library/Logs/Shentu/<app>/`, named by time plus a random part, so runs never share or overwrite them.

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
