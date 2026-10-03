#!/bin/bash
#
# Stub environment for the test suite.
#
# Puts fake pmset / defaults / launchctl / sudo / killall at the front of PATH so
# the script under test can be run end to end without changing anything on the
# machine it runs on.
#
# Every stub appends the command it was called with to $STUB_CALL_LOG, so a test
# can assert on exactly which commands were issued. Read-only invocations are
# answered from fixture files instead, which is what lets a test choose the
# "previous state" that the script will discover and back up.

set -uo pipefail

STUB_FIXTURES="${STUB_FIXTURES:-}"
STUB_CALL_LOG="${STUB_CALL_LOG:-}"
STUB_FAIL_MATCH="${STUB_FAIL_MATCH:-}"

stub_install() {
    STUB_DIR="$1"
    mkdir -p "$STUB_DIR" || return 1

    cat > "$STUB_DIR/sudo" <<'STUB'
#!/bin/bash
# Pretend to be sudo. Never prompts, never runs anything privileged, and never
# calls the real pmset — so failure injection has to live here, not in the pmset
# stub, because the script only ever reaches pmset through sudo.
printf 'sudo %s\n' "$*" >> "$STUB_CALL_LOG"
for needle in ${STUB_FAIL_MATCH//,/ }; do
    [[ "$*" == *"$needle"* ]] && exit 1
done
exit 0
STUB

    cat > "$STUB_DIR/pmset" <<'STUB'
#!/bin/bash
# `pmset -g` and `pmset -g batt` are reads: answer them from the fixtures so the
# test controls what the script believes the current power settings are. Reached
# only when pmset is called directly, which the script does not do for writes.
if [[ "$1" == "-g" ]]; then
    if [[ "$2" == "batt" ]]; then
        if [[ -f "$STUB_FIXTURES/battery.txt" ]]; then
            cat "$STUB_FIXTURES/battery.txt"
        else
            printf "Now drawing from 'AC Power'\n"
            printf " -InternalBattery-0 (id=0)\t100%%; AC attached\n"
        fi
        exit 0
    fi
    cat "$STUB_FIXTURES/pmset.txt"
    exit 0
fi
printf 'pmset %s\n' "$*" >> "$STUB_CALL_LOG"
for needle in ${STUB_FAIL_MATCH//,/ }; do
    [[ "$*" == *"$needle"* ]] && exit 1
done
exit 0
STUB

    cat > "$STUB_DIR/defaults" <<'STUB'
#!/bin/bash
# `defaults read <domain> <key>` is a read: answer it from the fixture. Anything
# that is not in the fixture behaves like an unset key, which exits 1, exactly
# as the real defaults(1) does.
if [[ "$1" == "read" ]]; then
    want="$2|$3"
    while IFS='|' read -r domain key value; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        if [[ "$domain|$key" == "$want" && -n "$value" ]]; then
            printf '%s\n' "$value"
            exit 0
        fi
    done < "$STUB_FIXTURES/defaults.tsv"
    exit 1
fi
printf 'defaults %s\n' "$*" >> "$STUB_CALL_LOG"
exit 0
STUB

    cat > "$STUB_DIR/launchctl" <<'STUB'
#!/bin/bash
# `launchctl print-disabled` is a read: answer it from the fixture.
if [[ "$1" == "print-disabled" ]]; then
    cat "$STUB_FIXTURES/launchctl.txt"
    exit 0
fi
printf 'launchctl %s\n' "$*" >> "$STUB_CALL_LOG"
exit 0
STUB

    cat > "$STUB_DIR/killall" <<'STUB'
#!/bin/bash
printf 'killall %s\n' "$*" >> "$STUB_CALL_LOG"
exit 0
STUB

    # sw_vers and sysctl are read-only and harmless, but pin them anyway so the
    # output is deterministic across machines.
    cat > "$STUB_DIR/sw_vers" <<'STUB'
#!/bin/bash
case "${1:-}" in
    -productVersion) echo "99.0" ;;
    -buildVersion)   echo "STUBBUILD1" ;;
    *) exit 1 ;;
esac
STUB

    cat > "$STUB_DIR/sysctl" <<'STUB'
#!/bin/bash
if [[ "$*" == *"hw.model"* ]]; then echo "StubModel1,1"; exit 0; fi
exit 1
STUB

    chmod +x "$STUB_DIR"/*
}

# stub_write_fixtures <dir> [defaults.tsv content file]
# Creates the three fixture files a stub reads. The defaults fixture is copied
# from the given file so a test can describe a different starting machine.
stub_write_fixtures() {
    local dir="$1" src="${2:-}"
    mkdir -p "$dir"

    cat > "$dir/pmset.txt" <<'EOF'
 Battery Power:
 Sleep On Power Button 1
 powermode            1
 standby              1
 ttyskeepawake        1
 hibernatemode        3
 powernap             1
 hibernatefile        /var/vm/sleepimage
 displaysleep         2
 womp                 0
 networkoversleep     0
 sleep                1
 tcpkeepalive         1
 lessbright           1
 disksleep            10
 SleepServices        0
AC Power:
 Sleep On Power Button 1
 powermode            2
 standby              1
 ttyskeepawake        1
 hibernatemode        3
 powernap             1
 hibernatefile        /var/vm/sleepimage
 displaysleep         10
 womp                 1
 networkoversleep     0
 sleep                1
 tcpkeepalive         1
 disksleep            0
 SleepServices        0
EOF

    # Defaults present before the run: one int, one bool, one string, and the
    # key containing a space that once got truncated to "Assistant".
    cat > "${src:-$dir/defaults.tsv}" <<'EOF'
# domain|key|value
NSGlobalDomain|KeyRepeat|6
NSGlobalDomain|InitialKeyRepeat|25
com.apple.dock|mineffect|genie
com.apple.assistant.support|Assistant Enabled|true
com.apple.CrashReporter|DialogType|always
EOF

    # Format taken verbatim from macOS 27 `launchctl print-disabled user/$UID`.
    # Note it says "disabled"/"enabled", NOT "true"/"false" — older releases used
    # booleans, and the script has to understand both.
    cat > "$dir/launchctl.txt" <<'EOF'

	disabled services = {
		"com.microsoft.teams2.agent" => enabled
		"com.apple.ManagedClientAgent.enrollagent" => disabled
		"com.apple.Siri.agent" => disabled
		"com.apple.suggestd" => enabled
		"com.apple.photoanalysisd" => enabled
		"com.apple.iconservicesd" => disabled
		"com.apple.suspend" => enabled
		"com.apple.osaccount" => enabled
	}
EOF
}
