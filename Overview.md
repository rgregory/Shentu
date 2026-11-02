# Shentu

Drop a Mac app on Shentu and it opens in a strongly isolated (seatbelt) sandbox.

## What you choose

**Internet and network.** Off means no internet or local-network connections.

**Files it can open — by kind.** Archive, Document, Image, Movie, Music, PDF, Presentation and Text (Finder's Kind names), each set to Off, Read, or Read & Write. Hover a name for its extensions.

- Read opens every file of that kind in your home folder and on drives (`/Volumes`).
- Read & Write also lets it create, change, rename and delete files of that kind there, and nowhere else.
- Apps that save through a temporary file with another name (NSDocument's safe save) can't save them.
- It can see file and folder names. System files and the app itself are always readable.
- Code, scripts and Finder's other kinds (Application, Executable, Other) aren't offered.

**Files it can open — only these.** Just the files and folders you pick, read-only (a folder includes everything inside it). Less access than a kind, which opens every matching file you have.

**Output folder.** Optional. One folder it can read, change and delete anything in, so its work survives the run. It must be inside your home folder or on a drive, and can't be your whole home folder, a whole drive, `~/Library`, or a protected place. Checked again at every launch.

**Keep its isolated data between runs.**

- On: the app gets a private home folder of its own, keyed by its path on disk (through `HOME` and `CFFIXED_USER_HOME`). Its existing data elsewhere and shared macOS preferences stay blocked. Apps that ignore this folder can't save settings.
- Off: no persistent storage. The output folder and Read & Write kinds still apply.

## Always on

- Any other file it saves goes to a temporary folder made for this run, deleted when it quits.
- It can't start other programs or open links.
- It can't connect to Unix-domain sockets (Docker's, ssh-agent's, other apps'), except the system log, and DNS when the network is on.
- It can only reach Apple's system services (Mach/XPC), and not Apple's container engine: no third-party helpers or engines that could act outside the sandbox.
- A built-in sanity set (secrets, other apps' data, persistence) is always blocked.
- Stop, or the app quitting, ends everything it started too.

## Runs and activity

Your choices are remembered per app.

Each run shows where it is: Starting, Running, Quit, Quit with an error (the exit code), Crashed (the signal), Stopped, or Launch failed (why). If the system log dropped messages, the run says its logging was incomplete.

**Activity** opens what the app was blocked from: grouped into Files, Network, Programs and Services, counted, searchable by path, address, service or process, and exportable as CSV. The raw log (JSON lines) is a click away.

**Expect some apps to complain.** Helpers using `posix_spawn` are blocked because it can move a child outside the launch group; bundled helpers using fork/exec remain supported. `setsid` and `setpgid` are also blocked, so detached helpers cannot outlive cleanup. Mac apps ignore TMPDIR (NSTemporaryDirectory always returns the shared per-user folder), so an app's normal temp and cache writes are blocked.

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
