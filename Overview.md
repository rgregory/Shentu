# Shentu

Drop a Mac app on Shentu and it opens in a strongly isolated (seatbelt) sandbox.

## What you choose

**Internet and network.** Off means no internet or local-network connections.

**Clipboard.** Off means it can't read what you've copied or put anything on the clipboard.

**Advanced.** Closed until you open it: which of your files the app can open, the output folder, and whether it keeps its data between runs. Every one of them starts at its safest setting, and the closed heading says in one line what it currently allows, so a choice remembered from last time is never hidden.

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
- It can only reach Apple's system services (Mach), and not the container engine, privileged-helper and package installers, admin prompts, login and background items, screen recording or Spotlight. With the network off, also not DNS or the system's background transfer service.
- No XPC services, its own included: macOS starts them outside the sandbox.
- It can't start launchd jobs, signal processes outside the sandbox, post keyboard or mouse input, or use the camera or microphone.
- Outside your home folder, other accounts, `/Users/Shared` and the temp folders all apps share are closed too. The rest of the system stays readable.
- It gets a short fixed environment, no terminal, and no input or output streams.
- A built-in sanity set (secrets, other apps' data, persistence) is always blocked.
- Stop, or the app quitting, ends everything it started too.
- Quitting Shentu stops every run it is watching, and each run's temp folder goes with it.

## Runs and activity

Your choices are remembered per app, by where it is and who signed it, not by the name it gives itself.

Each run shows where it is: Starting, Running, Quit, Quit with an error (the exit code), Crashed (the signal), Stopped, or Launch failed (why). If the system log dropped messages, the run says its logging was incomplete.

**Activity** opens what the app was blocked from: grouped into Files, Network, Programs and Services, counted, searchable by path, address, service or process, and exportable as CSV. The raw log (JSON lines) is a click away.

**Expect some apps to complain.** Helpers using `posix_spawn` are blocked because it can move a child outside the launch group; bundled helpers using fork/exec remain supported. `setsid` and `setpgid` are also blocked, so detached helpers cannot outlive cleanup. Mac apps ignore TMPDIR (NSTemporaryDirectory always returns the shared per-user folder), so an app's normal temp and cache writes are blocked.

## Apps that are already sandboxed

Apps in Apple's App Sandbox (most App Store apps) and Apple's own apps can't be wrapped: macOS won't put a second sandbox on a sandboxed app, and only launchd may start Apple's. Drop one on Shentu and it shows the restrictions the app already runs under, read from its code signature:

- App Sandbox and Hardened Runtime, on or off.
- One row per area (Network, Files, Devices, Personal data, Other): what it may do (✓) and what its sandbox keeps from it (✕). For example: ✓ connect out, files you pick; ✕ the rest of your home folder, Downloads, camera, contacts.
- Where it keeps its data: its container (`~/Library/Containers/<bundle ID>`), its app groups' containers, and any read & write exceptions. Click one to show it in Finder.
- **Your secrets**: whether it can read SSH keys, `.env` and key files, cloud and API credentials, password stores, shell history or browser sessions (the same set Shentu always blocks), and through what: no sandbox, the all-files entitlement, an exception over a folder that holds them, or Downloads. If nothing lets it, a green line says they're out of its reach.
- **Other gaps**: ways out of or around its own confinement, most serious first. Some come from its signature: code injection it allows (`DYLD_` variables, libraries signed by others, or no Hardened Runtime at all), control of other apps, services and places it may reach through sandbox exceptions, other apps' settings, shared app-group folders, and private Apple entitlements. Two are left open by the App Sandbox itself, and Shentu closes both: opening links and other apps (a link can carry data out even without network access), and reading most of the system outside your home folder.

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
