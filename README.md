# macOS Login & Responsiveness Optimization

A single self-contained script that fixes the **slow, unresponsive login screen**
caused by aggressive hibernation, and trims a set of macOS defaults that make the
UI feel sluggish.

Developed and tested on macOS 27.0.1 (26A434), Apple M2 Max (`Mac14,6`). It sticks
to `bash 3.2` syntax (what `/bin/bash` still is on macOS) and to `pmset`,
`defaults` and `launchctl` invocations that have been stable for many releases,
but **it has only actually been run on 27.0.1** — please open an issue if
something misbehaves on your version.

```
git clone https://github.com/wasim-osman/macos-optimization.git
cd macos-optimization
./macos-optimization.command --dry-run     # see what it would change
./macos-optimization.command               # apply
./macos-optimization.command --undo        # changed your mind
```

---

## Why the login screen hangs

On a Mac with a lot of RAM, macOS's default `hibernatemode 3` writes the **entire
contents of RAM to disk** every time the machine sleeps. On a 32 GB or 64 GB
machine that is a multi-gigabyte write. If the machine is woken part-way through
that write — which is exactly what happens when you close and reopen the lid, or
walk away from a desk — the restore has to replay the disk image before the
window server comes back.

The visible symptom is the login window appearing frozen for several seconds to
several minutes after a password is typed.

Disabling hibernation removes that write entirely. The cost is that you lose
"resume exactly where I was left off" across a full power loss, and that Fast
Sleep is gone (see [Laptops](#laptops-read-this-first)).

Everything else in the script is optional and independent of that fix — pick and
choose by running it, watching what it reports, and undoing anything you dislike.

---

## Requirements and permissions

This is the part people usually get stuck on, so it is spelled out.

| What you need | Why | Required? |
| --- | --- | --- |
| **An administrator account** | `pmset` changes live power state and is a root-only tool. The script calls `sudo` and prompts you. | **Yes** |
| **The executable bit** (`chmod +x`) | macOS only runs a `.command` file if it is executable. Git preserves this bit, so a normal `git clone` needs nothing extra. | **Yes** |
| **Terminal.app** | `.command` files are run by Terminal. Any terminal emulator works if you invoke it from a shell. | Yes |
| **Password entry at the prompt** | Only for the five `pmset` lines and the `rm` of the sleep image. Everything else runs unprivileged. | Yes |

### What you do *not* need

- **No Full Disk Access.** Nothing here reads or writes a protected folder
  except `/var/vm/sleepimage`, which `sudo` handles on its own.
- **No Accessibility, Automation or Screen Recording permission.** The script
  never asks for them and will never trigger those prompts.
- **No `sudo` for the whole script.** Do **not** run
  `sudo ./macos-optimization.command` — the script refuses to run as root
  (`error: Do not run this with sudo`) and prompts you per-command instead, so
  your admin password is only asked for where it is genuinely needed.

### If macOS blocks it

**Downloaded as a zip from the browser, or received via AirDrop / Messages:**
those routes attach a `com.apple.quarantine` attribute, and Gatekeeper then
refuses to run it. Clear it once:

```bash
xattr -dr com.apple.quarantine ~/Downloads/macos-optimization-main
```

**Cloned with `git` or `gh repo clone`:** no quarantine attribute is attached,
so this does not apply. Cloning is the clean path.

**`chmod +x` needed?** Only if you copy the file around with something that
drops permissions, or extracted it with a tool that ignored the mode bits:

```bash
chmod +x macos-optimization.command restore-defaults.command
```

**macOS asks Terminal for permission to access a folder** the first time a
script reaches outside your home directory (for example when removing
`/var/vm/sleepimage`). Choose **OK** / **Allow**. If you dismissed it by
accident, re-enable it under **System Settings → Privacy & Security → Files and
Folders → Terminal**.

---

## Usage

| Command | Effect |
| --- | --- |
| `./macos-optimization.command --dry-run` | Prints every change, touches nothing, never asks for a password. Safe on any Mac. |
| `./macos-optimization.command` | Shows the confirmation prompt, then applies the **full** profile. |
| `./macos-optimization.command --profile minimal` | Applies only the login-hang fix. See [Profiles](#profiles). |
| `./macos-optimization.command --profile full` | The default. Everything below. |
| `./macos-optimization.command -y` | No confirmation prompt. For scripting. |
| `./macos-optimization.command --undo` | Restores the state captured before the first apply. |
| `./macos-optimization.command --help` | Usage summary. |
| `./restore-defaults.command` | Standalone double-clickable alias for `--undo`. |

### Profiles

Only one of the power settings — `hibernatemode 0` — actually fixes the slow
login screen. Everything else in this repo is preference. So there are two sets:

| | `--profile minimal` | `--profile full` (default) |
| --- | --- | --- |
| `hibernatemode 0`, sleep image, `powernap 0`, `sleep 10` | yes | yes |
| `standby`, `autopoweroff` (Fast Sleep) | **no** | yes — unless you are asked, see below |
| `proximitywake 0` | **no** | yes |
| UI responsiveness | **no** | yes |
| Background processes / Siri | **no** | yes |
| Text substitutions | **no** | yes |
| Safe on a laptop | yes | see below |

**If you are not sure, run `--profile minimal`.** It is the whole fix for the
problem the README describes and nothing else, and it leaves Fast Sleep alone so
it is safe on a MacBook. Once you have restarted and confirmed the login stall
is gone, re-run with `--profile full` if you want the rest.

`--undo` works identically after either profile.

### Fast Sleep: the script asks you

On a laptop, Fast Sleep is the one setting where "optimised" and "correct" point
in opposite directions. A Mac that never sleeps is fast; a Mac that sleeps
properly is not flat in your bag by lunchtime. No profile can decide that for
you, so on a laptop the script stops and asks:

```
Fast Sleep is currently OFF
  Turning it on means the Mac sleeps properly when the lid is
  shut, using more battery. Turning it off keeps the Mac
  running with the lid shut, which is faster but flatter.

  [1] Turn Fast Sleep ON
  [2] Turn Fast Sleep OFF
  [3] Leave it as it is

  Choice [3]:
```

Whatever you pick beats the profile. Choose **3** or just press Enter to leave
Fast Sleep exactly as it is — that is the safe default.

On a **desktop** you are not asked, because the question does not apply. On an
older Intel Mac that does not report the current value, the script says it cannot
tell rather than guessing.

To answer without a prompt — a script, or any unattended run:

| `MACOS_OPT_FAST_SLEEP` | Effect |
| --- | --- |
| `on` | turn Fast Sleep on |
| `off` | turn Fast Sleep off |
| `keep` | follow the profile, change nothing |

### Add it to the Dock

Drag `macos-optimization.command` onto the Dock. macOS adds it as a
terminal-launcher tile; clicking it opens a Terminal window and runs the script.
Keep `restore-defaults.command` next to it and drag that in too, so the undo is
one click away.

### Put it in a folder

If you would rather keep it in a folder than on the Dock, drop both `.command`
files into `~/Applications` (create it if it does not exist) and double-click
from Finder.

---

## What it changes

`set -e` was replaced with per-command error handling in v2, because several of
these keys **do not exist on every Mac**. On a desktop with no proximity sensor,
for example, `pmset -a proximitywake 0` fails — and under the original script
that one line aborted everything after it. Now a rejected key is reported as
skipped and the run continues.

### Power settings

| Setting | Change to | Effect |
| --- | --- | --- |
| `hibernatemode` | `0` | **The main fix.** No more RAM-to-disk write on sleep. |
| `/var/vm/sleepimage` | deleted | Frees disk. Only exists while hibernation is on, so usually already absent. |
| `standby` | `0` | Disables Fast Sleep (see laptops). |
| `autopoweroff` | `0` | Disables the timer that sleeps an idle Mac after a while. |
| `powernap` | `0` | Stops the Mac waking itself for background mail/Time Machine. |
| `sleep` | `10` | Sleep after 10 minutes idle instead of the shorter default. |
| `proximitywake` | `0` | Laptops only — disables waking on approach. Skipped on desktops. |

### UI responsiveness

| Setting | Change to | Effect |
| --- | --- | --- |
| `KeyRepeat` | `2` | Key repeat starts almost immediately. |
| `InitialKeyRepeat` | `15` | Same, from a shorter delay. |
| `NSWindowResizeTime` | `0.1` | Windows snap open instead of animating. |
| `com.apple.dock autohide-delay` | `0.1` | Dock appears instantly. |
| `com.apple.dock autohide-time-modifier` | `0.3` | Shorter Dock slide. |
| `com.apple.dock mineffect` | `scale` | Replaces the "genie" effect with the cheap scale. |
| `com.apple.finder DisableAllAnimations` | `true` | No Finder window animation. |

### Background processes

| Setting | Change to | What you lose |
| --- | --- | --- |
| `com.apple.assistant.support` → `Assistant Enabled` | `false` | Siri. |
| `com.apple.Siri` → `StatusMenuVisible` | `false` | The Siri menu bar item. |
| `com.apple.Siri` → `UserHasDeclinedEnable` | `true` | Stops macOS re-prompting you to turn Siri back on. |
| `com.apple.Siri.agent` | disabled | The Siri agent itself. |
| `com.apple.suggestd` | disabled | **Spotlight web/suggestion results.** Local app search still works. |
| `com.apple.photoanalysisd` | disabled | Automatic "Photos" groupings and scene detection. Your library is untouched. |
| `com.apple.iconservicesd` | disabled | Icon cache lookups. Can make newly created files show a generic icon until reboot. |
| `com.apple.CrashReporter` → `DialogType` | `none` | Crash dialogs. Crashes are still logged to `/Library/Logs/DiagnosticReports`. |

### Text substitutions

`NSAutomaticSpellingCorrectionEnabled`, `NSAutomaticCapitalizationEnabled`,
`NSAutomaticDashSubstitutionEnabled`, `NSAutomaticPeriodSubstitutionEnabled`,
`NSAutomaticQuoteSubstitutionEnabled` — all set to `false`. Stops macOS from
rewriting what you type: no smart quotes, no `--` becoming an en dash, no
sentence capitalisation.

> This one is a matter of taste rather than performance, and it is the setting
> people most often want back. `--undo` restores all five.

---

## Laptops: read this first

`standby 0` and `autopoweroff 0` disable **Fast Sleep** (S3). Without it, a
closed MacBook does not park its memory and power down — it keeps running with
the lid shut, drawing real power.

That means a MacBook in a backpack can be **flat battery by lunchtime**, and heat
builds in a bag. So on a laptop the script **asks** whether you want Fast Sleep
turned off, and shows you its current state — see
[Fast Sleep: the script asks you](#fast-sleep-the-script-asks-you). Answer **3**
to leave it alone and get the login fix without the battery cost.

If you skip the prompt with `-y`, use `--profile minimal`, or want to be
explicit, answer it yourself:

```bash
MACOS_OPT_FAST_SLEEP=keep ./macos-optimization.command -y
```

Everything else in the script is laptop-safe.

---

## Undoing

`--undo` is not a guess. Before the first apply, the script writes the previous
value of **every** setting it is about to touch to:

```
~/Library/Application Support/macos-optimization/state.tsv
```

`--undo` reads that file and puts each value back, including deleting keys that
did not previously exist and re-enabling daemons it disabled. Re-running the
apply later does not overwrite the original baseline — the second run writes a
timestamped `state-<date>.tsv` alongside it and `--undo` keeps using the original,
so you can never end up with a "default" that is actually your optimised state.

If the backup file is missing, `--undo` falls back to the documented macOS
defaults (`hibernatemode 3`, `standby 1`, `autopoweroff 1`, `powernap 1`,
`sleep 1`, `proximitywake 1`) and deletes the `defaults` keys, which returns them
to their factory state.

### What undo cannot restore

Two keys are one-way, and it is worth being straight about it:

| Key | Why |
| --- | --- |
| `autopoweroff` | macOS does not report the current value, so there is nothing to put back. After an undo it stays `0`. |
| `proximitywake` | Same, and most Macs have no proximity sensor to begin with. |

`standby` **is** restored, because macOS does report it. If you want
`autopoweroff` back after an undo, set it yourself:

```bash
sudo pmset -a autopoweroff 1
```

### Note on macOS re-enabling services

A macOS major upgrade often **re-enables** `suggestd` and `photoanalysisd` on its
own. If Siri suggestions or photo groupings come back after an update, that is
macOS, not a bug here. Re-run the script, or just the two `launchctl disable`
lines.

---

## Files

| File | What it is |
| --- | --- |
| `macos-optimization.command` | The script. Everything else defers to it. |
| `restore-defaults.command` | Thin wrapper that calls `macos-optimization.command --undo`. Exists so the undo is a separate double-clickable file. |
| [`macos_optimization.md`](macos_optimization.md) | The original notes this script was written from, kept for reference. |
| [`tests/run-tests.sh`](tests/run-tests.sh) | The test suite. Safe to run; it changes nothing. |
| `LICENSE` | MIT. |

### About `macos_optimization.md`

It is the hand-written source document — plain `bash` blocks grouped by topic,
each one annotated with a comment explaining why. It is the readable version of
what the script automates, and it is genuinely useful in two ways the script
cannot cover:

1. **Copy-paste individual commands.** If you only want one change — say, faster
   key repeat, and nothing else — you can lift that single block out of the
   markdown and paste it into Terminal. You do not have to run all 30 changes to
   get one of them.
2. **Audit before you trust.** It is short enough to read end to end in a couple
   of minutes, so you can see every command before running anything, rather than
   trusting a script you downloaded.

The `.command` file is that document turned into something executable, with the
confirmation prompt, the backup, and the undo added. The two are kept in the repo
together on purpose: the markdown explains *why*, the script does *what*, and
neither replaces the other.

---

## Contributing

`./tests/run-tests.sh` runs the whole suite. It replaces `pmset`, `defaults`,
`launchctl`, `sudo` and `killall` with stubs that record what they were asked to
do, and points the backup at a temp directory — so the full apply → undo round
trip runs for real, safely, on any machine including CI. Nothing it does can
change your settings.

```bash
./tests/run-tests.sh          # everything
./tests/run-tests.sh undo     # only tests matching "undo"
```

The same suite runs on every push and pull request. It also checks the README
against the script, so a new setting that is not documented fails the build.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the invariants a change must not
break.

## License

MIT. See [LICENSE](LICENSE).
