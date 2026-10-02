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
   dry-run branch.
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

There is no test suite yet, which is itself a welcome contribution. Until there
is one, please check at minimum:

```bash
bash -n macos-optimization.command          # syntax
./macos-optimization.command --dry-run      # no side effects, no password prompt
./macos-optimization.command --help
```

`--dry-run` is safe to run anywhere. The full apply is not — run it in a VM or on
a machine you can undo, and always finish with:

```bash
./macos-optimization.command --undo
```

The baseline backup lives in
`~/Library/Application Support/macos-optimization/state.tsv`. `MACOS_OPT_STATE_DIR`
overrides that path, which is what makes it possible to test capture and restore
without touching real settings — please use it rather than writing to the real
directory.

## Style

- 4-space indent, `[[ ]]` over `[ ]`, `printf` over `echo`.
- One `run "<what it does>" <command...>` call per setting, with the reason in a
  comment above it where it is not obvious.
- Keep the summary lines the user actually reads. The script is deliberately
  chatty — every change is named, and anything skipped is named too.

## Commit messages

Plain imperative subject, one logical change per commit. Explain *why* in the
body when the reason is not obvious from the diff.
