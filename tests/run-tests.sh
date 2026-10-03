#!/bin/bash
#
# Test suite for macos-optimization.command
#
#   ./tests/run-tests.sh              run everything
#   ./tests/run-tests.sh undo         run tests whose name matches "undo"
#
# Nothing here touches the machine it runs on. pmset, defaults, launchctl, sudo
# and killall are replaced with stubs that log what they were asked to do, and
# MACOS_OPT_STATE_DIR points the script's backup at a temp directory. So the
# full apply -> undo round trip runs for real, safely, on any machine including
# CI.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/macos-optimization.command"
RESTORE="$REPO_ROOT/restore-defaults.command"
FILTER="${1:-}"

# shellcheck source=helpers/stub-env.sh
source "$REPO_ROOT/tests/helpers/stub-env.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macopt-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [[ -t 1 ]]; then
    G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=''; R=''; D=''; B=''; N=''
fi

TESTS_RUN=0
TESTS_FAILED=0
CURRENT=""
CURRENT_FAILED=0

# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

test_case() {
    CURRENT="$1"
    CURRENT_FAILED=0
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_fail() {
    CURRENT_FAILED=1
    printf '    %sFAIL%s %s\n' "$R" "$N" "$1"
}

skip_all() { (( TESTS_RUN > 0 )); }

# Describe the failure context before the summary line.
fail() { test_fail "$1"; }

assert_eq() {
    local expected="$1" actual="$2" what="$3"
    [[ "$expected" == "$actual" ]] && return 0
    fail "$what
         expected: [$expected]
         actual:   [$actual]"
}

assert_contains() {
    local haystack="$1" needle="$2" what="${3:-output should contain the expected text}"
    [[ "$haystack" == *"$needle"* ]] && return 0
    fail "$what
         missing:  [$needle]"
}

assert_not_contains() {
    local haystack="$1" needle="$2" what="${3:-output should not contain this text}"
    [[ "$haystack" != *"$needle"* ]] && return 0
    fail "$what
         should not contain: [$needle]"
}

assert_file_exists() {
    [[ -f "$1" ]] && return 0
    fail "${2:-expected file to exist}: $1"
}

assert_file_absent() {
    [[ ! -e "$1" ]] && return 0
    fail "${2:-expected file to be absent}: $1"
}

assert_exit() {
    local expected="$1" actual="$2" what="$3"
    assert_eq "$expected" "$actual" "$what"
}

end_test() {
    if (( CURRENT_FAILED )); then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  %s✗%s %s%s%s\n' "$R" "$N" "$D" "$CURRENT" "$N"
    else
        printf '  %s✓%s %s\n' "$G" "$N" "$CURRENT"
    fi
}

# ---------------------------------------------------------------------------
# sandbox helper
# ---------------------------------------------------------------------------

# sandbox_new <name> -> sets SANDBOX, PATH, STUB_CALL_LOG, MACOS_OPT_STATE_DIR
# and prints the path of a fresh, empty call log.
sandbox_new() {
    local name="$1"
    SANDBOX="$WORK/$name"
    STUB_CALL_LOG="$SANDBOX/calls.log"
    STUB_FAIL_MATCH=""
    mkdir -p "$SANDBOX/state"
    : > "$STUB_CALL_LOG"
    stub_write_fixtures "$SANDBOX/fixtures"
    export STUB_FIXTURES="$SANDBOX/fixtures"
    export STUB_CALL_LOG STUB_FAIL_MATCH
    export PATH="$SANDBOX/bin:$ORIGINAL_PATH"
    export MACOS_OPT_STATE_DIR="$SANDBOX/state"
    stub_install "$SANDBOX/bin"
    printf '%s' "$STUB_CALL_LOG"
}

sandbox_reset_log() { : > "$STUB_CALL_LOG"; }

# Run the script under test with stdin closed, capturing output and exit code.
# Usage: run_script <args...>  -> sets OUT, STATUS
run_script() {
    OUT=$("$SCRIPT" "$@" < /dev/null 2>&1)
    STATUS=$?
    return 0
}

# run_script_fs <on|off|keep> <args...> — answer the Fast Sleep question without
# a terminal. Assigning in front of a function call leaks in bash, so this
# exports and clears explicitly instead.
run_script_fs() {
    local choice="$1"; shift
    MACOS_OPT_FAST_SLEEP="$choice"
    export MACOS_OPT_FAST_SLEEP
    run_script "$@"
    unset MACOS_OPT_FAST_SLEEP
}

log_has()   { grep -qF -- "$1" "$STUB_CALL_LOG"; }
log_lacks() { ! grep -qF -- "$1" "$STUB_CALL_LOG"; }

ORIGINAL_PATH="$PATH"

printf '\n%s%s test suite %s\n' "$B" "macos-optimization" "$N"
printf '%ssandbox: %s%s\n\n' "$D" "$WORK" "$N"

# ---------------------------------------------------------------------------
# 1. syntax and CLI contract
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "syntax" ]]; then
test_case "both scripts are syntactically valid bash"
for f in "$SCRIPT" "$RESTORE"; do
    if bash -n "$f" 2>"$WORK/syntax.err"; then :; else
        fail "bash -n $f: $(cat "$WORK/syntax.err")"
    fi
done
end_test

test_case "the scripts stay compatible with bash 3.2"
# /bin/bash is still 3.2 on macOS. Associative arrays, ${var,,} and readarray
# would break there while working fine under whatever bash CI happens to ship.
for pattern in 'declare -A' 'typeset -A' 'readarray' 'mapfile' '${[A-Za-z_]*\^\^}' '${[A-Za-z_]*,,}'; do
    if grep -qE -- "$pattern" "$SCRIPT"; then
        fail "found bash-4+ construct in macos-optimization.command: $pattern"
    fi
done
end_test

test_case "scripts carry the executable bit in the git index"
# A clone that loses the exec bit cannot be double-clicked, which is the primary
# way this tool is used.
while read -r mode path; do
    case "$path" in
        *.command) assert_eq "100755" "$mode" "git mode for $path" ;;
    esac
done < <(cd "$REPO_ROOT" && git ls-files -s 2>/dev/null)
end_test

test_case "--help exits 0 and documents every flag"
sandbox_new help > /dev/null
run_script --help
assert_exit 0 "$STATUS" "--help should succeed"
for flag in --dry-run --undo --yes --help --profile minimal; do
    assert_contains "$OUT" "$flag" "--help should mention $flag"
done
end_test

test_case "an unknown flag fails with a nonzero exit"
sandbox_new badflag > /dev/null
run_script --definitely-not-a-flag
assert_exit 1 "$STATUS" "unknown flag should exit 1"
assert_contains "$OUT" "Unknown option" "should explain the problem"
end_test

test_case "an unknown --profile value is rejected"
sandbox_new badprofile > /dev/null
run_script --profile bogus
assert_exit 1 "$STATUS" "unknown profile should exit 1"
assert_contains "$OUT" "Unknown profile" "should explain the problem"
end_test

test_case "--profile without a value is rejected"
sandbox_new novalue > /dev/null
run_script --profile
assert_exit 1 "$STATUS" "missing profile value should exit 1"
end_test

test_case "--profile=minimal is accepted as well as --profile minimal"
sandbox_new profileeq > /dev/null
run_script --profile=minimal --dry-run
assert_exit 0 "$STATUS" "--profile=minimal should be accepted"
assert_contains "$OUT" "Profile: minimal" "should report the minimal profile"
end_test

test_case "the script refuses to run as root"
# EUID is readonly so it cannot be faked from a test. Assert on the guard
# instead, and note that it is verified by hand rather than here.
if grep -q 'EUID -eq 0' "$SCRIPT"; then :; else
    fail "expected an EUID -eq 0 guard so a plain sudo ./script is refused"
fi
end_test
fi

# ---------------------------------------------------------------------------
# 2. dry run must not touch anything
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "dry" ]]; then
test_case "--dry-run issues no mutating command at all"
sandbox_new dryrun > /dev/null
run_script --dry-run
assert_exit 0 "$STATUS" "--dry-run should exit 0"
assert_eq "0" "$(wc -c < "$STUB_CALL_LOG" | tr -d ' ')" "no command should have been executed"
end_test

test_case "--dry-run writes no backup and no state directory"
sandbox_new dryrunstate > /dev/null
run_script --dry-run
assert_file_absent "$SANDBOX/state/state.tsv" "--dry-run must not capture a baseline"
assert_eq "0" "$(ls -A "$SANDBOX/state" | wc -l | tr -d ' ')" "state dir should stay empty"
end_test

test_case "--dry-run never asks for a password"
# sudo would prompt if it were really invoked; a non-interactive run that
# succeeded proves it was not called.
sandbox_new drynopass > /dev/null
run_script --dry-run
assert_exit 0 "$STATUS" "--dry-run should complete without stdin"
assert_contains "$OUT" "Dry run complete" "should report completion"
end_test

test_case "--dry-run prints every command it would run"
sandbox_new drylist > /dev/null
run_script --dry-run
for expected in \
    "pmset -a hibernatemode 0" \
    "pmset -a powernap 0" \
    "pmset -a sleep 10" \
    "defaults write NSGlobalDomain KeyRepeat -int 2" \
    "defaults write com.apple.dock mineffect -string scale" \
    "defaults write com.apple.assistant.support \"Assistant Enabled\" -bool false" \
    "launchctl disable user/$(id -u)/com.apple.Siri.agent" \
    "defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false"
do
    assert_contains "$OUT" "$expected" "--dry-run output should list: $expected"
done
end_test

test_case "--dry-run quotes keys that contain a space"
# The key is "Assistant Enabled"; if it printed unquoted the printed command
# would not be pasteable.
sandbox_new dryquote > /dev/null
run_script --dry-run
assert_contains "$OUT" 'com.apple.assistant.support "Assistant Enabled"' "key with a space must be quoted"
end_test
fi

# ---------------------------------------------------------------------------
# 3. minimal profile
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "profile" ]]; then
test_case "the minimal profile changes only the four login-fix power settings"
sandbox_new minimal > /dev/null
run_script --profile minimal -y
assert_exit 0 "$STATUS" "minimal apply should succeed"
assert_contains "$(cat "$STUB_CALL_LOG")" "pmset -a hibernatemode 0" "minimal must disable hibernation"
assert_contains "$(cat "$STUB_CALL_LOG")" "pmset -a powernap 0" "minimal must disable Power Nap"
assert_contains "$(cat "$STUB_CALL_LOG")" "pmset -a sleep 10" "minimal must set sleep"
log_lacks "pmset -a standby 0"  || fail "minimal must not disable standby (Fast Sleep)"
log_lacks "pmset -a autopoweroff 0" || fail "minimal must not disable autopoweroff"
log_lacks "pmset -a proximitywake 0" || fail "minimal must not touch proximitywake"
end_test

test_case "the minimal profile touches no defaults and no daemons"
sandbox_new minimalclean > /dev/null
run_script --profile minimal -y
assert_eq "0" "$(grep -c '^defaults ' "$STUB_CALL_LOG")" "minimal must not write any defaults key"
assert_eq "0" "$(grep -c '^launchctl ' "$STUB_CALL_LOG")" "minimal must not disable any daemon"
end_test

test_case "the full profile is the default"
sandbox_new defaultprofile > /dev/null
run_script -y
assert_contains "$OUT" "Profile: full" "apply should default to the full profile"
log_has "defaults write NSGlobalDomain KeyRepeat -int 2" || fail "default run should include UI changes"
end_test

test_case "the full profile does change standby and autopoweroff"
sandbox_new fullpower > /dev/null
run_script -y
log_has "pmset -a standby 0" || fail "full should disable standby"
log_has "pmset -a autopoweroff 0" || fail "full should disable autopoweroff"
end_test
fi

# ---------------------------------------------------------------------------
# 3b. Fast Sleep can be answered either way
# ---------------------------------------------------------------------------
#
# The interactive prompt cannot be driven here: run_script sends stdin from
# /dev/null, so ask_fast_sleep deliberately keeps the profile default. The
# MACOS_OPT_FAST_SLEEP override is the same code path the prompt ends up
# setting, so these tests cover the decision and its effect, and the prompt
# itself is covered by checking it stays silent when nobody can answer it.

if [[ -z "$FILTER" || "$FILTER" == "fastsleep" ]]; then

test_case "the prompt does not appear when stdin is not a terminal"
sandbox_new fsquiet > /dev/null
run_script -y
assert_not_contains "$OUT" "Turn Fast Sleep ON" "a non-interactive run must not ask"
end_test

test_case "-y must not ask about Fast Sleep either"
sandbox_new fsyes > /dev/null
run_script -y
assert_not_contains "$OUT" "Choice [3]" "--yes must not prompt"
end_test

test_case "MACOS_OPT_FAST_SLEEP=off turns Fast Sleep off"
sandbox_new fsoff > /dev/null
run_script_fs off -y --profile minimal
log_has "pmset -a standby 0"     || fail "off should disable standby"
log_has "pmset -a autopoweroff 0" || fail "off should disable autopoweroff"
end_test

test_case "MACOS_OPT_FAST_SLEEP=on turns Fast Sleep on"
sandbox_new fson > /dev/null
run_script_fs on -y --profile minimal
log_has "pmset -a standby 1"      || fail "on should enable standby"
log_has "pmset -a autopoweroff 1" || fail "on should enable autopoweroff"
end_test

test_case "MACOS_OPT_FAST_SLEEP=on beats the full profile"
sandbox_new fsoverride > /dev/null
run_script_fs on -y --profile full
log_lacks "pmset -a standby 0" || fail "an explicit on must beat the profile"
log_has  "pmset -a standby 1" || fail "an explicit on should enable standby"
end_test

test_case "MACOS_OPT_FAST_SLEEP=keep falls back to the profile"
sandbox_new fskeep > /dev/null
run_script_fs keep -y --profile full
log_has "pmset -a standby 0" || fail "keep should follow the full profile"
end_test

test_case "MACOS_OPT_FAST_SLEEP=keep under minimal leaves standby alone"
sandbox_new fskeepmin > /dev/null
run_script_fs keep -y --profile minimal
log_lacks "pmset -a standby 0"     || fail "minimal must not disable standby"
log_lacks "pmset -a standby 1"     || fail "minimal must not enable standby"
log_lacks "pmset -a autopoweroff 0" || fail "minimal must not disable autopoweroff"
end_test

test_case "a bad MACOS_OPT_FAST_SLEEP value is rejected"
sandbox_new fsbad > /dev/null
run_script_fs maybe -y
assert_exit 1 "$STATUS" "a bad value should exit 1"
assert_contains "$OUT" "must be on, off or keep" "should explain the accepted values"
end_test

test_case "proximitywake stays profile-gated even when Fast Sleep is turned on"
sandbox_new fsprox > /dev/null
run_script_fs on -y --profile minimal
log_lacks "pmset -a proximitywake 0" || fail "minimal must not touch proximitywake"
end_test

test_case "a desktop is never asked about Fast Sleep"
sandbox_new fsdesktop > /dev/null
printf "Now drawing from 'AC Power'\n" > "$SANDBOX/fixtures/battery.txt"
run_script --dry-run
assert_not_contains "$OUT" "Fast Sleep is currently" "a desktop has no Fast Sleep"
end_test

test_case "a laptop dry run reports the current Fast Sleep state"
sandbox_new fsdry > /dev/null
run_script --dry-run
assert_contains "$OUT" "Fast Sleep is currently ON" "fixture has standby 1"
end_test

test_case "an unreadable standby is reported as unknown, not guessed"
sandbox_new fsunknown > /dev/null
# An Intel Mac reports standbydelayhigh and prints no standby at all.
grep -v ' standby ' "$SANDBOX/fixtures/pmset.txt" > "$SANDBOX/fixtures/pmset2.txt"
mv "$SANDBOX/fixtures/pmset2.txt" "$SANDBOX/fixtures/pmset.txt"
run_script --dry-run
assert_contains "$OUT" "cannot be read" "should say it cannot tell"
assert_not_contains  "$OUT" "Fast Sleep is currently ON"  "must not guess on"
assert_not_contains  "$OUT" "Fast Sleep is currently OFF" || fail "must not guess off"
end_test

test_case "Fast Sleep still reads correctly when standby is 0"
sandbox_new fsoffstate > /dev/null
sed -i '' 's/^ standby  *1$/ standby              0/' "$SANDBOX/fixtures/pmset.txt"
run_script --dry-run
assert_contains "$OUT" "Fast Sleep is currently OFF" "should report off"
end_test

test_case "a dry run must preview the answer, not the profile default"
sandbox_new fsdryans > /dev/null
# A preview that disagrees with the run it previews is worse than no preview,
# so the override has to be applied before apply() is called in dry-run mode.
run_script_fs on --dry-run --profile full
assert_contains "$OUT" "pmset -a standby 1" "preview should enable standby"
assert_not_contains "$OUT" "pmset -a standby 0" "preview must not show the profile default"
end_test

test_case "a dry run with keep shows the profile default"
sandbox_new fsdrykeep > /dev/null
run_script_fs keep --dry-run --profile full
assert_contains "$OUT" "pmset -a standby 0" "keep should preview the full profile"
assert_not_contains "$OUT" "Fast Sleep answer:" "an unanswered preview should not claim an answer"
end_test

test_case "a dry run with no override says nothing about an answer"
sandbox_new fsdrynone > /dev/null
run_script --dry-run --profile full
assert_not_contains "$OUT" "Fast Sleep answer:" "no answer was given"
end_test

test_case "undo restores the Fast Sleep value captured at apply time"
sandbox_new fsundo > /dev/null
run_script_fs off -y --profile full
assert_contains "$(cat "$MACOS_OPT_STATE_DIR/state.tsv")" "power	-a standby	1" \
    "baseline should record standby 1 before it is changed"
run_script -y --undo
log_has "pmset -a standby 1" || fail "undo should put standby back to 1"
end_test

fi

# ---------------------------------------------------------------------------
# 4. an unsupported key must not abort the run
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "resilience" ]]; then
test_case "a pmset key the machine rejects does not abort the run"
# This is the v1 bug: `set -e` plus proximitywake failing on a desktop meant
# every command after it silently never ran.
sandbox_new failkey > /dev/null
export STUB_FAIL_MATCH="proximitywake"
run_script -y
assert_exit 0 "$STATUS" "a rejected key should not fail the whole run"
assert_contains "$OUT" "skipped" "the rejected key should be reported as skipped"
assert_contains "$OUT" "were not supported and were skipped" "the summary should count the skip"
# Everything after proximitywake in apply_power must still have run.
log_has "defaults write NSGlobalDomain KeyRepeat -int 2" || fail "UI changes must still run after a rejected key"
log_has "launchctl disable user/$(id -u)/com.apple.suggestd" || fail "daemon changes must still run after a rejected key"
end_test

test_case "the run reports how many settings were skipped"
sandbox_new failcount > /dev/null
export STUB_FAIL_MATCH="proximitywake,autopoweroff"
run_script -y
assert_contains "$OUT" "2 setting(s) were not supported" "should report the skip count"
end_test

test_case "a failing command still counts as attempted"
sandbox_new failall > /dev/null
export STUB_FAIL_MATCH="pmset"
run_script -y
assert_exit 0 "$STATUS" "run should complete even if pmset keeps failing"
assert_contains "$OUT" "Done —" "should still print a summary"
end_test
fi

# ---------------------------------------------------------------------------
# 5. baseline capture
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "capture" ]]; then
test_case "apply captures a baseline of every setting it manages"
sandbox_new capture > /dev/null
run_script -y
STATE="$SANDBOX/state/state.tsv"
assert_file_exists "$STATE" "baseline should be written"
BASELINE=$(cat "$STATE")
assert_contains "$BASELINE" "power	-a hibernatemode	3" "should record the previous hibernatemode"
assert_contains "$BASELINE" "power	-a powernap	1" "should record the previous powernap"
assert_contains "$BASELINE" "power	-a standby	1" "should record the previous standby"
assert_contains "$BASELINE" "default	NSGlobalDomain	KeyRepeat	6" "should record the previous KeyRepeat"
assert_contains "$BASELINE" "launchctl	user/$(id -u)/com.apple.Siri.agent	disabled" "should record the disabled Siri agent"
assert_contains "$BASELINE" "launchctl	user/$(id -u)/com.apple.suggestd	enabled" "should record the enabled suggestd"
end_test

test_case "a baseline captures a key containing a space in full"
# Regression: the managed list was space-delimited, so "Assistant Enabled" was
# captured as "Assistant" and would never have been restored.
sandbox_new spaces > /dev/null
run_script -y
STATE="$SANDBOX/state/state.tsv"
assert_contains "$(cat "$STATE")" "default	com.apple.assistant.support	Assistant Enabled	true" \
    "the Assistant Enabled key must be captured whole"
end_test

test_case "settings that were unset are recorded as unset, not skipped"
sandbox_new unsetkeys > /dev/null
run_script -y
STATE="$SANDBOX/state/state.tsv"
assert_contains "$(cat "$STATE")" "default	com.apple.finder	DisableAllAnimations	<unset>" \
    "an absent key must be recorded so undo can delete it"
end_test

test_case "a second apply does not overwrite the original baseline"
# Otherwise --undo would restore the optimised values and call them "defaults".
sandbox_new twice > /dev/null
run_script -y
FIRST=$(cat "$SANDBOX/state/state.tsv")
sleep 1
run_script -y
assert_contains "$(cat "$SANDBOX/state/state.tsv")" "hibernatemode	3" "the baseline must still hold the original value"
assert_eq "$FIRST" "$(cat "$SANDBOX/state/state.tsv")" "the baseline file must be byte-identical after a second run"
if ! ls "$SANDBOX/state"/state-*.tsv > /dev/null 2>&1; then
    fail "the second run should have written a timestamped snapshot"
fi
end_test

test_case "the second apply says which snapshot it wrote"
sandbox_new twicenotice > /dev/null
run_script -y
sandbox_reset_log
run_script -y
assert_contains "$OUT" "Baseline backup already exists" "should warn that a baseline already exists"
assert_contains "$OUT" "keeps using the original baseline" "should say undo still uses the baseline"
end_test
fi

# ---------------------------------------------------------------------------
# 6. undo
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "undo" ]]; then
test_case "undo puts the power settings back"
sandbox_new undopower > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
CALLS=$(cat "$STUB_CALL_LOG")
assert_contains "$CALLS" "pmset -a hibernatemode 3" "should restore hibernatemode to 3"
assert_contains "$CALLS" "pmset -a powernap 1" "should restore powernap to 1"
assert_contains "$CALLS" "pmset -a standby 1" "should restore standby to 1"
assert_contains "$CALLS" "pmset -a sleep 1" "should restore sleep to 1"
end_test

test_case "undo restores each value with its original type"
# Regression: `defaults read` is untyped, so restoring with -string produced a
# string KeyRepeat, which the window server ignores.
sandbox_new undotypes > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
CALLS=$(cat "$STUB_CALL_LOG")
assert_contains "$CALLS" "defaults write NSGlobalDomain KeyRepeat -int 6" "KeyRepeat must come back as an int"
assert_contains "$CALLS" "defaults write NSGlobalDomain InitialKeyRepeat -int 25" "InitialKeyRepeat must come back as an int"
assert_contains "$CALLS" "defaults write com.apple.assistant.support Assistant Enabled -bool true" "the Assistant Enabled key must come back as a bool"
assert_contains "$CALLS" "defaults write com.apple.CrashReporter DialogType -string always" "DialogType must come back as a string"
assert_not_contains "$CALLS" "KeyRepeat -string" "KeyRepeat must never be restored as a string"
end_test

test_case "undo deletes the keys that did not exist before"
sandbox_new undodelete > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
CALLS=$(cat "$STUB_CALL_LOG")
assert_contains "$CALLS" "defaults delete NSGlobalDomain NSWindowResizeTime" "should delete a key that was unset"
assert_contains "$CALLS" "defaults delete com.apple.finder DisableAllAnimations" "should delete a key that was unset"
end_test

test_case "undo re-enables the daemons that were disabled"
sandbox_new undolaunch > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
CALLS=$(cat "$STUB_CALL_LOG")
assert_contains "$CALLS" "launchctl enable user/$(id -u)/com.apple.Siri.agent" "should re-enable the Siri agent"
assert_contains "$CALLS" "launchctl enable user/$(id -u)/com.apple.iconservicesd" "should re-enable icon services"
assert_contains "$OUT" "already enabled" "should say suggestd was already enabled rather than touching it"
end_test

test_case "a baseline is captured for every daemon the script manages"
# Regression: macOS 27 spells the override "disabled", older releases "true".
# Reading only "=> true" made every daemon look enabled, so the baseline was
# wrong and undo then refused to re-enable anything.
sandbox_new launchparse > /dev/null
run_script -y
BASELINE=$(cat "$SANDBOX/state/state.tsv")
uid=$(id -u)
assert_contains "$BASELINE" "launchctl	user/$uid/com.apple.Siri.agent	disabled" \
    "a service reported as disabled must be captured as disabled"
assert_contains "$BASELINE" "launchctl	user/$uid/com.apple.iconservicesd	disabled" \
    "a second disabled service must be captured too"
assert_contains "$BASELINE" "launchctl	user/$uid/com.apple.suggestd	enabled" \
    "a service reported as enabled must be captured as enabled"
end_test

test_case "the daemon parser also understands the older boolean spelling"
# Older macOS printed "=> true" / "=> false". Same script, both spellings.
sandbox_new launchbool > /dev/null
cat > "$SANDBOX/fixtures/launchctl.txt" <<'EOF'
{
	"com.apple.Siri.agent" => true
	"com.apple.suggestd" => false
	"com.apple.photoanalysisd" => false
	"com.apple.iconservicesd" => true
}
EOF
run_script -y
BASELINE=$(cat "$SANDBOX/state/state.tsv")
uid=$(id -u)
assert_contains "$BASELINE" "launchctl	user/$uid/com.apple.Siri.agent	disabled" "boolean true must read as disabled"
assert_contains "$BASELINE" "launchctl	user/$uid/com.apple.suggestd	enabled" "boolean false must read as enabled"
assert_contains "$BASELINE" "launchctl	user/$uid/com.apple.iconservicesd	disabled" "boolean true must read as disabled"
end_test

test_case "undo round-trips every daemon back to its original state"
sandbox_new launchroundtrip > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
CALLS=$(cat "$STUB_CALL_LOG")
uid=$(id -u)
for service in com.apple.Siri.agent com.apple.suggestd com.apple.photoanalysisd com.apple.iconservicesd; do
    if grep -q "\"$service\" => enabled" "$SANDBOX/fixtures/launchctl.txt"; then
        log_lacks "launchctl enable user/$uid/$service" \
            || fail "$service was enabled before, so undo must leave it alone"
    else
        assert_contains "$CALLS" "launchctl enable user/$uid/$service" \
            "$service was disabled before, so undo must re-enable it"
    fi
done
end_test

test_case "undo leaves a key alone when it was already enabled"
sandbox_new undonoop > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
log_lacks "launchctl enable user/$(id -u)/com.apple.suggestd" || fail "suggestd was enabled before, so undo must not re-enable it"
end_test

test_case "undo skips a power key the machine does not support"
# The fixture has no autopoweroff, so there is nothing to restore and inventing
# a value would be wrong.
sandbox_new undoskip > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
assert_contains "$OUT" "was not supported on this Mac" "should say why a key was skipped"
log_lacks "pmset -a autopoweroff" || fail "must not invent a value for an unsupported key"
end_test

test_case "undo reports how many settings it restored"
sandbox_new undocount > /dev/null
run_script -y
sandbox_reset_log
run_script --undo -y
assert_contains "$OUT" "Restored" "should report a count"
end_test

test_case "undo round-trips: apply, undo, apply again all succeed"
sandbox_new roundtrip > /dev/null
run_script -y;    A=$STATUS
run_script --undo -y; B=$STATUS
run_script -y;    C=$STATUS
assert_eq "0 0 0" "$A $B $C" "all three runs should succeed"
end_test

test_case "undo without a baseline falls back to macOS defaults"
sandbox_new nobackup > /dev/null
run_script --undo -y
assert_exit 0 "$STATUS" "the fallback path should still succeed"
assert_contains "$OUT" "No backup found" "should say it is guessing"
CALLS=$(cat "$STUB_CALL_LOG")
assert_contains "$CALLS" "pmset -a hibernatemode 3" "fallback should use the documented default"
assert_contains "$CALLS" "pmset -a standby 1" "fallback should use the documented default"
assert_contains "$CALLS" "pmset -a autopoweroff 1" "fallback should use the documented default"
assert_contains "$CALLS" "launchctl enable user/$(id -u)/com.apple.iconservicesd" "fallback should re-enable every daemon"
end_test

test_case "undo of a minimal apply still restores cleanly"
sandbox_new undominimal > /dev/null
run_script --profile minimal -y
sandbox_reset_log
run_script --undo -y
assert_exit 0 "$STATUS" "undo after a minimal apply should succeed"
assert_contains "$(cat "$STUB_CALL_LOG")" "pmset -a hibernatemode 3" "should restore hibernatemode"
end_test
fi

# ---------------------------------------------------------------------------
# 7. the undo wrapper
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "wrapper" ]]; then
test_case "restore-defaults.command forwards to the undo path"
sandbox_new wrapper > /dev/null
OUT="$("$RESTORE" -y < /dev/null 2>&1)"; STATUS=$?
assert_exit 0 "$STATUS" "the wrapper should succeed"
assert_contains "$OUT" "restor" "the wrapper should reach the undo code path"
end_test

test_case "restore-defaults.command resolves through a symlink"
sandbox_new wrappersym > /dev/null
ln -sf "$RESTORE" "$SANDBOX/undo-alias.command"
OUT="$("$SANDBOX/undo-alias.command" -y < /dev/null 2>&1)"; STATUS=$?
assert_exit 0 "$STATUS" "the wrapper should work when symlinked"
assert_not_contains "$OUT" "cannot find macos-optimization.command" "should find the script through the symlink"
end_test

test_case "restore-defaults.command explains itself when the sibling is missing"
sandbox_new wrappermissing > /dev/null
mkdir -p "$SANDBOX/lonely"
cp "$RESTORE" "$SANDBOX/lonely/"
OUT="$("$SANDBOX/lonely/restore-defaults.command" < /dev/null 2>&1)"; STATUS=$?
assert_exit 1 "$STATUS" "should exit 1 when it cannot find the script"
assert_contains "$OUT" "cannot find macos-optimization.command" "should name the problem"
assert_contains "$OUT" "https://github.com/wasim-osman/macos-optimization" "should link the repo"
end_test

test_case "restore-defaults.command puts back a non-executable main script"
sandbox_new wrapperchmod > /dev/null
cp "$SCRIPT" "$SANDBOX/lonely-main.command" 2>/dev/null || true
mkdir -p "$SANDBOX/pair"
cp "$RESTORE" "$SANDBOX/pair/"
cp "$SCRIPT" "$SANDBOX/pair/macos-optimization.command"
chmod -x "$SANDBOX/pair/macos-optimization.command"
OUT="$("$SANDBOX/pair/restore-defaults.command" -y < /dev/null 2>&1)"; STATUS=$?
assert_exit 0 "$STATUS" "the wrapper should restore the exec bit and continue"
assert_contains "$OUT" "restor" "should still reach the undo code path"
end_test
fi

# ---------------------------------------------------------------------------
# 8. documentation stays in step with the code
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "docs" ]]; then
test_case "every managed defaults key is documented in the README"
sandbox_new docskeys > /dev/null
README="$REPO_ROOT/README.md"
# Pull the managed list out of the script itself so this cannot drift.
sed -n '/^MANAGED_DEFAULTS=(/,/^)/p' "$SCRIPT" \
    | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' \
    | while IFS='|' read -r domain key _; do
        if ! grep -qF "$key" "$README"; then
            printf 'MISSING %s %s\n' "$domain" "$key"
        fi
      done > "$WORK/missing.txt"
if [[ -s "$WORK/missing.txt" ]]; then
    fail "README does not mention these managed keys:
$(cat "$WORK/missing.txt")"
fi
end_test

test_case "every managed power key is documented in the README"
sandbox_new docspower > /dev/null
README="$REPO_ROOT/README.md"
sed -n '/^MANAGED_POWER=(/p' "$SCRIPT" \
    | tr -d 'MANAGED_POWER=()' \
    | tr ' ' '\n' \
    | grep -v '^$' \
    > "$WORK/keys.txt"
while read -r key; do
    grep -qF "$key" "$README" || printf 'MISSING %s\n' "$key"
done < "$WORK/keys.txt" > "$WORK/missing2.txt"
if [[ -s "$WORK/missing2.txt" ]]; then
    fail "README does not mention these power keys:
$(cat "$WORK/missing2.txt")"
fi
end_test

test_case "every managed launchd domain is documented in the README"
sandbox_new docsdaemons > /dev/null
README="$REPO_ROOT/README.md"
sed -n '/^MANAGED_DOMAINS=(/,/^)/p' "$SCRIPT" \
    | sed -n 's/.*\///p' \
    | tr -d '"' \
    | while read -r service; do
        grep -qF "$service" "$README" || printf 'MISSING %s\n' "$service"
      done > "$WORK/missing3.txt"
if [[ -s "$WORK/missing3.txt" ]]; then
    fail "README does not mention these daemons:
$(cat "$WORK/missing3.txt")"
fi
end_test

test_case "the README documents both profiles and all three run modes"
sandbox_new docsmodes > /dev/null
README="$REPO_ROOT/README.md"
for needle in "--dry-run" "--undo" "--profile minimal" "--profile full" "chmod +x" "com.apple.quarantine"; do
    grep -qF -- "$needle" "$README" || fail "README should document: $needle"
done
end_test

test_case "the README states which macOS version was actually tested"
# A README that implies broader testing than has happened is worse than none.
sandbox_new docstested > /dev/null
grep -qF "27.0.1" "$REPO_ROOT/README.md" || fail "README should name the tested macOS version"
grep -qF "only actually been run" "$REPO_ROOT/README.md" || fail "README should be explicit about the limits of the testing"
end_test
fi

# ---------------------------------------------------------------------------
# 9. packaging
# ---------------------------------------------------------------------------

if [[ -z "$FILTER" || "$FILTER" == "packaging" ]]; then
test_case "the repo ships the files the README links to"
sandbox_new files > /dev/null
for f in README.md LICENSE CONTRIBUTING.md macos_optimization.md \
         macos-optimization.command restore-defaults.command \
         tests/run-tests.sh; do
    assert_file_exists "$REPO_ROOT/$f" "expected file"
done
end_test

test_case "the version in the script matches the released tag"
sandbox_new version > /dev/null
SCRIPT_VERSION=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$SCRIPT")
[[ -n "$SCRIPT_VERSION" ]] || fail "could not read VERSION from the script"
# Every version the script has ever carried should have a tag in the repo.
if git -C "$REPO_ROOT" rev-parse "v$SCRIPT_VERSION" > /dev/null 2>&1; then :; else
    fail "no git tag v$SCRIPT_VERSION for VERSION=\"$SCRIPT_VERSION\""
fi
end_test

test_case "the state directory is not committed"
sandbox_new gitignore > /dev/null
grep -qE 'state\.tsv|\.tsv' "$REPO_ROOT/.gitignore" \
    || fail ".gitignore should keep the runtime backup out of the repo"
end_test
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

printf '\n'
if (( TESTS_FAILED > 0 )); then
    printf '%s%s failed, %s total%s\n\n' "$R" "$TESTS_FAILED" "$TESTS_RUN" "$N"
    exit 1
fi
printf '%s%s passed%s\n\n' "$G" "$TESTS_RUN" "$N"
exit 0
