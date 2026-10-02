# Contributing

Thanks for looking at this. It is a small script, so the bar for a change is
mostly about **not breaking the safety properties**.

## Open an issue first for anything behavioural

Several `pmset` keys are hardware-dependent. `proximitywake` only exists on
laptops with a proximity sensor; `standby` and `autopoweroff` behave differently
on Apple silicon. If you want to add or change a setting, open an issue with:

- `sw_vers -productVersion`
- `sysctl -n hw.model`
- whether the machine is a laptop or a desktop

before writing code, so nobody discovers the problem on their own machine.

## Invariants a change must not break

1. **`--dry-run` never modifies anything and never prompts for a password.**
   The only exception allowed is creating the empty state directory. If your
   change touches anything, it belongs behind `run()`, which already handles the
   dry-run branch. `capture_state()` returns early on dry-run for the same reason.
2. **`--undo` must be able to reverse your change.** Any new `defaults`, `pmset`
   or `launchctl` key has to be added in three places, or undo will silently
   leave it behind:
   - `MANAGED_DEFAULTS` (`domain|key|type` — pipe-delimited, because
     `Assistant Enabled` contains a space) or `MANAGED_POWER` +
     `POWER_DEFAULTS` or `MANAGED_DOMAINS`
   - a row in the relevant table in `README.md`
   - the `apply()` function
3. **One unsupported key must not abort the run.** That was the main bug in v1:
   `set -e` meant a single `pmset` key the machine rejected stopped everything
   after it. Keep going through `run()` and report failures as skipped. Do not
   reintroduce `set -e`.
4. **Stay on bash 3.2.** `/bin/bash` on macOS is still 3.2.57, so no associative
   arrays (`declare -A`), no `${var,,}`, no `mapfile`/`readarray`.
5. **Do not introduce new TCC permission prompts.** The script deliberately needs
   no Full Disk Access and no Accessibility/Automation access. Keep it that way —
   it is a documented selling point in the README.

## Testing

```bash
./tests/run-tests.sh          # everything
./tests/run-tests.sh undo     # only tests whose name matches "undo"
```

The suite replaces `pmset`, `defaults`, `launchctl`, `sudo` and `killall` with
stubs on a temporary `PATH`, and points the script's backup at a temp directory
via `MACOS_OPT_STATE_DIR`. The full apply → undo round trip therefore runs for
real — it is not mocked at the script level — but **it cannot change your
settings**, because nothing privileged is ever executed. It runs on every push
and pull request on macOS 14 and macOS 15.

`tests/helpers/stub-env.sh` builds the stub commands. The read-only ones
(`pmset -g`, `defaults read`, `launchctl print-disabled`) answer from fixture
files, which is how a test chooses the "previous state" the script will discover
and back up. `STUB_FAIL_MATCH` makes matching commands exit non-zero, which is
how the "a rejected key must not abort the run" tests work.

Two tests worth knowing about because they have caught real bugs:

- **the daemon parser tests** pin both the `=> disabled` spelling used by current
  macOS and the older `=> true` spelling. Reading only one of them made every
  daemon look enabled, so the baseline was wrong and `--undo` refused to
  re-enable anything.
- **the README consistency tests** extract `MANAGED_DEFAULTS`, `MANAGED_POWER`
  and `MANAGED_DOMAINS` out of the script and require every key to appear in the
  README, so a new setting that is not documented fails the build.

If you add a `--flag`, add a test for the CLI contract (accepted value, rejected
value, exit code) alongside the behaviour test.

## Versioning

`VERSION` in the script must match a released git tag. The suite fails if
`VERSION="2.3.0"` has no `v2.3.0` tag, so after bumping the version:

```bash
git commit -am "v2.3.0: ..."
git tag -a v2.3.0 -m "v2.3.0"
git push --follow-tags
gh release create v2.3.0 --generate-notes
```

Do not attach the `.command` files as release assets. Anything downloaded gets
a `com.apple.quarantine` attribute from the browser, which then blocks
double-clicking — the same problem the README's permissions section explains.
Cloning the tag does not have that problem.

## Style

- 4-space indent, `[[ ]]` over `[ ]`, `printf` over `echo`.
- One `run "<what it does>" <command...>` call per setting, with the reason in a
  comment above it where it is not obvious.
- Keep the summary lines the user actually reads. The script is deliberately
  chatty — every change is named, and anything skipped is named too.

## Commit messages

Plain imperative subject, one logical change per commit. Explain *why* in the
body when the reason is not obvious from the diff.
