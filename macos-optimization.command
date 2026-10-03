#!/bin/bash
#
# macOS Login & Responsiveness Optimization
# https://github.com/wasim-osman/macos-optimization
#
# Double-click to run, or:
#   ./macos-optimization.command                     apply the full profile
#   ./macos-optimization.command --profile minimal   only the login-hang fix
#   ./macos-optimization.command --dry-run           print every change, change nothing
#   ./macos-optimization.command --undo              restore the state saved before the first run
#
# Sudo password will be required.

set -uo pipefail

VERSION="2.1.0"
STATE_DIR="${MACOS_OPT_STATE_DIR:-$HOME/Library/Application Support/macos-optimization}"
STATE_FILE="$STATE_DIR/state.tsv"
FAILURES=0
DRY_RUN=0
ASSUME_YES=0
UNDO=0
PROFILE="full"

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; RESET=''
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
skip() { printf '    %s-%s %s%s%s\n' "$DIM" "$RESET" "$DIM" "$*" "$RESET"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
macOS Login & Responsiveness Optimization

USAGE
  macos-optimization.command [options]

OPTIONS
  --profile <minimal|full>
                Which set of changes to make. Default: full.

                  full     Everything: the login fix plus UI, background
                           process and text substitution changes.
                  minimal  Only the settings that address the slow login
                           screen. Touches four power values and nothing
                           else. Safe on a laptop, because it leaves Fast
                           Sleep alone.

  --dry-run     Print every change that would be made, then exit. No sudo
                prompt, nothing is modified. Safe to run on any machine.
  --undo        Restore the settings captured before the *first* apply run.
                Falls back to macOS defaults if no backup exists.
  -y, --yes     Do not prompt for confirmation.
  -h, --help    Show this help.

NOTES
  * An administrator account is required: the power settings use sudo.
  * No Full Disk Access, Accessibility or Automation permission is needed.
  * Every change is logged to ~/Library/Application Support/macos-optimization/
EOF
}

# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------

# run <description> <command...>
# Echoes the command, runs it, and keeps going if the machine rejects it.
# Some pmset keys do not exist on every Mac (proximitywake on desktops, standby
# on Apple silicon laptops) and a hard failure there must not abort the run.
run() {
    local desc="$1"; shift
    local cmd_str="" arg

    # Quote args containing spaces so the echoed command can be pasted as-is.
    for arg in "$@"; do
        [[ "$arg" == *" "* ]] && arg="\"$arg\""
        cmd_str+="${cmd_str:+ }$arg"
    done

    if (( DRY_RUN )); then
        printf '    %s[dry-run]%s %s\n' "$YELLOW" "$RESET" "$desc"
        printf '             %s$ %s%s\n' "$DIM" "$cmd_str" "$RESET"
        return 0
    fi

    if output=$("$@" 2>&1); then
        ok "$desc"
        [[ -n "$output" ]] && printf '             %s%s%s\n' "$DIM" "$output" "$RESET"
    else
        FAILURES=$((FAILURES + 1))
        warn "$desc — skipped"
        printf '             %s%s%s\n' "$DIM" "$output" "$RESET"
    fi
}

# ---------------------------------------------------------------------------
# state capture / restore
# ---------------------------------------------------------------------------

# The defaults we manage, as "domain|key|type". Pipe-delimited because one of
# the keys ("Assistant Enabled") contains a space. Used for both the pre-flight
# backup and the restore, so the two can never drift apart.
MANAGED_DEFAULTS=(
    "NSGlobalDomain|KeyRepeat|int"
    "NSGlobalDomain|InitialKeyRepeat|int"
    "NSGlobalDomain|NSWindowResizeTime|float"
    "NSGlobalDomain|NSAutomaticSpellingCorrectionEnabled|bool"
    "NSGlobalDomain|NSAutomaticCapitalizationEnabled|bool"
    "NSGlobalDomain|NSAutomaticDashSubstitutionEnabled|bool"
    "NSGlobalDomain|NSAutomaticPeriodSubstitutionEnabled|bool"
    "NSGlobalDomain|NSAutomaticQuoteSubstitutionEnabled|bool"
    "com.apple.dock|autohide-delay|float"
    "com.apple.dock|autohide-time-modifier|float"
    "com.apple.dock|mineffect|string"
    "com.apple.finder|DisableAllAnimations|bool"
    "com.apple.assistant.support|Assistant Enabled|bool"
    "com.apple.Siri|StatusMenuVisible|bool"
    "com.apple.Siri|UserHasDeclinedEnable|bool"
    "com.apple.CrashReporter|DialogType|string"
)

MANAGED_DOMAINS=(
    "user/$UID/com.apple.Siri.agent"
    "user/$UID/com.apple.suggestd"
    "user/$UID/com.apple.photoanalysisd"
    "user/$UID/com.apple.iconservicesd"
)

# Power settings, with the stock value each one falls back to.
MANAGED_POWER=(hibernatemode standby autopoweroff powernap sleep proximitywake)

POWER_DEFAULTS=(3 1 1 1 1 1)

# defaults_type_for <domain> <key>
# Linear scan rather than an associative array: /bin/bash on macOS is still
# 3.2, which has no associative arrays.
defaults_type_for() {
    local want_domain="$1" want_key="$2" entry domain key type
    for entry in "${MANAGED_DEFAULTS[@]}"; do
        IFS='|' read -r domain key type <<< "$entry"
        if [[ "$domain" == "$want_domain" && "$key" == "$want_key" ]]; then
            printf '%s' "$type"
            return 0
        fi
    done
    printf 'string'
}

capture_state() {
    # --dry-run must not touch the filesystem at all, not even to write a
    # backup that will be thrown away.
    (( DRY_RUN )) && return 0

    mkdir -p "$STATE_DIR"

    # The baseline must stay the state from *before* the first apply, or --undo
    # would only ever restore the already-optimized values. Later runs get
    # their own timestamped snapshot instead of overwriting the baseline.
    if [[ -f "$STATE_FILE" ]]; then
        local stamp extra
        stamp=$(date +%Y%m%d-%H%M%S)
        extra="$STATE_DIR/state-$stamp.tsv"
        STATE_FILE="$extra"
        warn "Baseline backup already exists — writing this run's snapshot to"
        warn "  $(basename "$extra")"
        say "  ${DIM}(--undo keeps using the original baseline)${RESET}"
    fi

    : > "$STATE_FILE"
    {
        printf '# macos-optimization %s state, captured %s\n' "$VERSION" "$(date)"
        printf '# <kind>\t<target>\t<previous value>\n'
    } >> "$STATE_FILE"

    local entry domain key type value
    for entry in "${MANAGED_DEFAULTS[@]}"; do
        IFS='|' read -r domain key type <<< "$entry"
        value=$(defaults read "$domain" "$key" 2>/dev/null)
        printf 'default\t%s\t%s\t%s\n' "$domain" "$key" "${value:-<unset>}" >> "$STATE_FILE"
    done

    local i key
    for i in "${!MANAGED_POWER[@]}"; do
        key="${MANAGED_POWER[$i]}"
        value=$(pmset -g 2>/dev/null | awk -v k="$key" '$1 == k { print $2; exit }')
        printf 'power\t-a %s\t%s\n' "$key" "${value:-<unsupported>}" >> "$STATE_FILE"
    done

    local domain state service
    for domain in "${MANAGED_DOMAINS[@]}"; do
        # print-disabled labels services by name, not by full domain path.
        # The value has been spelled both "true"/"false" and "disabled"/"enabled"
        # across macOS releases, so accept either rather than assuming one.
        service="${domain##*/}"
        state=$(launchctl print-disabled "user/$UID" 2>/dev/null | awk -v d="$service" '
            index($0, "\"" d "\"") {
                n = split($0, parts, "=>")
                v = parts[2]
                gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (v == "true" || v == "disabled")     print "disabled"
                else if (v == "false" || v == "enabled") print "enabled"
                else                                      print "absent"
                exit
            }')
        printf 'launchctl\t%s\t%s\n' "$domain" "${state:-absent}" >> "$STATE_FILE"
    done

    say "    ${DIM}Saved current settings to $STATE_FILE${RESET}"
}

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

apply_power() {
    head1 "Power settings (the main fix)"

    # Hibernation writes the whole of RAM to disk on sleep. On large-memory
    # machines that write is slow, and waking mid-write is what produces the
    # long, unresponsive stall at the login window.
    capture_state
    run "Disable hibernation" sudo pmset -a hibernatemode 0

    # Only present when hibernation is on, so this is usually a no-op.
    run "Remove sleep image" sudo rm -f /var/vm/sleepimage

    # Power Nap schedules background work that wakes the machine on its own.
    run "Disable Power Nap" sudo pmset -a powernap 0
    run "Set sleep to 10 minutes" sudo pmset -a sleep 10

    # standby and autopoweroff are Fast Sleep. Turning them off means a laptop
    # keeps drawing real power with the lid shut, so they are in the full
    # profile only — the hibernation fix does not need them.
    if [[ "$PROFILE" == "full" ]]; then
        run "Disable standby (Fast Sleep)" sudo pmset -a standby 0
        run "Disable auto-power-off" sudo pmset -a autopoweroff 0

        # Laptops with a proximity sensor only. Desktops reject this key, which
        # is why run() tolerates a non-zero exit instead of aborting the script.
        run "Disable proximity wake" sudo pmset -a proximitywake 0
    else
        skip "standby 0 / autopoweroff 0 / proximitywake 0 (full profile only)"
    fi
}

apply_ui() {
    head1 "UI responsiveness"
    run "Faster key repeat" defaults write NSGlobalDomain KeyRepeat -int 2
    run "Shorter initial key repeat delay" defaults write NSGlobalDomain InitialKeyRepeat -int 15
    run "Faster window resize" defaults write NSGlobalDomain NSWindowResizeTime -float 0.1
    run "Faster Dock auto-hide" defaults write com.apple.dock autohide-delay -float 0.1
    run "Faster Dock animation" defaults write com.apple.dock autohide-time-modifier -float 0.3
    run "Dock genie->scale effect" defaults write com.apple.dock mineffect -string scale
    run "Disable Finder animations" defaults write com.apple.finder DisableAllAnimations -bool true
    run "Restart Dock" killall Dock
    run "Restart Finder" killall Finder
}

apply_background() {
    head1 "Background processes"
    run "Disable Siri" defaults write com.apple.assistant.support "Assistant Enabled" -bool false
    run "Hide Siri menu bar item" defaults write com.apple.Siri StatusMenuVisible -bool false
    run "Mark Siri as declined" defaults write com.apple.Siri UserHasDeclinedEnable -bool true
    run "Disable Siri agent" launchctl disable "user/$UID/com.apple.Siri.agent"
    run "Disable Spotlight suggestions" launchctl disable "user/$UID/com.apple.suggestd"
    run "Disable photo analysis" launchctl disable "user/$UID/com.apple.photoanalysisd"
    run "Disable icon services" launchctl disable "user/$UID/com.apple.iconservicesd"
    run "Silence crash reporter dialogs" defaults write com.apple.CrashReporter DialogType -string none
}

apply_text() {
    head1 "Automatic text substitutions"
    run "Disable autocorrect" defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
    run "Disable auto-capitalization" defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
    run "Disable smart dashes" defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
    run "Disable smart periods" defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
    run "Disable smart quotes" defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
}

apply() {
    apply_power

    if [[ "$PROFILE" == "full" ]]; then
        apply_ui
        apply_background
        apply_text
    else
        head1 "UI, background processes and text substitutions"
        skip "skipped — minimal profile. Re-run without --profile for these."
    fi
}

# ---------------------------------------------------------------------------
# undo
# ---------------------------------------------------------------------------

# Stock values used when no backup file exists.
restore_power_defaults() {
    local i key
    for i in "${!MANAGED_POWER[@]}"; do
        key="${MANAGED_POWER[$i]}"
        run "Restore $key to ${POWER_DEFAULTS[$i]}" sudo pmset -a "$key" "${POWER_DEFAULTS[$i]}"
    done
}

restore_with_backup() {
    [[ -f "$STATE_FILE" ]] || die "No backup found at $STATE_FILE. Nothing to undo."

    say "    ${DIM}Restoring from $STATE_FILE${RESET}"
    local kind a b value key domain
    local restored=0

    while IFS=$'\t' read -r kind a b value; do
        [[ "$kind" == \#* || -z "$kind" ]] && continue
        case "$kind" in
            power)
                # a = "-a <key>", b = previous value
                key="${a#-a }"
                if [[ "$b" == "<unsupported>" || -z "$b" ]]; then
                    skip "$key (was not supported on this Mac)"
                    continue
                fi
                run "Restore $key to $b" sudo pmset -a "$key" "$b"
                (( restored++ ))
                ;;
            default)
                domain="$a"; key="$b"
                if [[ "$value" == "<unset>" ]]; then
                    run "Delete $domain $key" defaults delete "$domain" "$key"
                else
                    # defaults read is untyped, so take the declared type from
                    # MANAGED_DEFAULTS — restoring KeyRepeat as a string would
                    # be silently ignored by the window server.
                    case "$(defaults_type_for "$domain" "$key")" in
                        int)   run "Restore $domain $key to $value" defaults write "$domain" "$key" -int "$value" ;;
                        float) run "Restore $domain $key to $value" defaults write "$domain" "$key" -float "$value" ;;
                        bool)  run "Restore $domain $key to $value" defaults write "$domain" "$key" -bool "$value" ;;
                        *)     run "Restore $domain $key to $value" defaults write "$domain" "$key" -string "$value" ;;
                    esac
                fi
                (( restored++ ))
                ;;
            launchctl)
                domain="$a"
                if [[ "$b" == "disabled" ]]; then
                    run "Re-enable $domain" launchctl enable "$domain"
                else
                    skip "$domain (was already enabled)"
                fi
                (( restored++ ))
                ;;
        esac
    done < "$STATE_FILE"

    say ""
    say "    ${DIM}Restored $restored settings.${RESET}"

    head1 "UI responsiveness"
    run "Restart Dock" killall Dock
    run "Restart Finder" killall Finder
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --undo)     UNDO=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        --profile)
            [[ $# -ge 2 ]] || die "--profile needs a value: minimal or full"
            shift
            case "$1" in
                minimal|full) PROFILE="$1" ;;
                *) die "Unknown profile: $1 (expected minimal or full)" ;;
            esac
            ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            case "$PROFILE" in
                minimal|full) ;;
                *) die "Unknown profile: $PROFILE (expected minimal or full)" ;;
            esac
            ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] && die "Do not run this with sudo — it asks for the password itself."

say "==============================================="
say " macOS Login & Responsiveness Optimization"
say "==============================================="
say ""
say "macOS : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
say "Mac   : $(sysctl -n hw.model 2>/dev/null || echo unknown)"
say ""
if (( UNDO )); then
    if (( ! ASSUME_YES )); then
        say "This will restore the settings saved before the first apply run."
        read -r -p "Continue? [y/N] " confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { say "Aborted."; exit 0; }
    fi
    say ""
    if [[ -f "$STATE_FILE" ]]; then
        restore_with_backup
    else
        warn "No backup found — restoring macOS defaults instead."
        say ""
        restore_power_defaults
        for entry in "${MANAGED_DEFAULTS[@]}"; do
            IFS='|' read -r domain key type <<< "$entry"
            run "Delete $domain $key" defaults delete "$domain" "$key"
        done
        for domain in "${MANAGED_DOMAINS[@]}"; do
            run "Re-enable $domain" launchctl enable "$domain"
        done
        run "Restart Dock" killall Dock
        run "Restart Finder" killall Finder
    fi
elif (( DRY_RUN )); then
    say "Dry run — nothing will be changed. Profile: $PROFILE"
    say ""
    apply
    say ""
    say "==============================================="
    say " Dry run complete. Nothing was modified."
    say "==============================================="
    exit 0
else
    if [[ "$PROFILE" == "minimal" ]]; then
        say "Profile: minimal"
        say ""
        say "This will change four power settings only:"
        say "  - Disable hibernation and remove the sleep image"
        say "  - Disable Power Nap"
        say "  - Set sleep to 10 minutes"
        say ""
        say "Fast Sleep, the UI tweaks, Siri and the text substitutions"
        say "are all left alone. Safe to run on a laptop."
        say ""
    else
        say "Profile: full"
        say ""
        say "This will:"
        say "  - Disable hibernation, standby, autopoweroff, Power Nap"
        say "  - Set sleep to 10 minutes"
        say "  - Speed up UI (key repeat, Dock, Finder animations)"
        say "  - Disable Siri, background daemons, text substitutions"
        say ""
        say "On a laptop this disables Fast Sleep, so expect higher idle"
        say "battery use. Prefer --profile minimal on a laptop."
    fi
    say ""
    say "Undo at any time with:  $0 --undo"
    say ""
    if (( ! ASSUME_YES )); then
        read -r -p "Continue? [y/N] " confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { say "Aborted."; exit 0; }
    fi
    say ""
    apply
fi

say ""
say "==============================================="
if (( FAILURES > 0 )); then
    say " Done — $FAILURES setting(s) were not supported and were skipped."
else
    say " Done!"
fi
say "==============================================="
say ""
say "Next steps:"
say "  1. Restart your Mac"
say "  2. Test login — the unresponsiveness should be gone"
say "  3. Undo with: $0 --undo"
say ""

# Only pause when a person is actually watching. With stdin closed or piped
# (a test, a CI run, `./script -y < /dev/null`) read would return 1 and, as the
# last command in the file, that became the script's exit status — so a fully
# successful run reported failure.
if [[ -t 0 ]]; then
    read -r -p "Press Enter to close..." _
fi

exit 0
