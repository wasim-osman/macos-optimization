#!/bin/bash

# macOS Login & Responsiveness Optimization
# Self-executable script — double-click to run (or run in Terminal).
# Sudo password will be required.

set -e

echo "==============================================="
echo " macOS Login & Responsiveness Optimization"
echo "==============================================="
echo ""
echo "This will:"
echo "  - Disable hibernation, standby, autopoweroff, powernap"
echo "  - Adjust sleep settings"
echo "  - Speed up UI (key repeat, Dock, Finder animations)"
echo "  - Disable Siri, background daemons, text substitutions"
echo ""
read -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "==> Power Settings (Main Fix)..."

# Disable hibernation (prevents RAM-to-disk save causing long wake delays)
sudo pmset -a hibernatemode 0

# Remove sleep image to free disk space
sudo rm -f /var/vm/sleepimage

# Disable standby and autopoweroff
sudo pmset -a standby 0
sudo pmset -a autopoweroff 0

# Disable powernap (background tasks triggering sleep/wake)
sudo pmset -a powernap 0

# Set sleep to 10 minutes (default may be 1 min)
sudo pmset -a sleep 10

# Disable proximity wake
sudo pmset -a proximitywake 0

echo "==> UI Responsiveness..."

# Faster key repeat
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15

# Faster Dock autohide
defaults write com.apple.dock autohide-delay -float 0.1
defaults write com.apple.dock autohide-time-modifier -float 0.3
defaults write com.apple.dock mineffect -string "scale"
killall Dock

# Faster window resize
defaults write NSGlobalDomain NSWindowResizeTime -float 0.1

# Disable Finder animations
defaults write com.apple.finder DisableAllAnimations -bool true
killall Finder

echo "==> Disabling Background Processes..."

# Disable Siri and Suggestions
defaults write com.apple.assistant.support "Assistant Enabled" -bool false
defaults write com.apple.Siri StatusMenuVisible -bool false
defaults write com.apple.Siri UserHasDeclinedEnable -bool true

# Disable background daemons
launchctl disable user/$UID/com.apple.Siri.agent
launchctl disable user/$UID/com.apple.suggestd
launchctl disable user/$UID/com.apple.photoanalysisd
launchctl disable user/$UID/com.apple.iconservicesd

# Disable crash reporter dialog
defaults write com.apple.CrashReporter DialogType -string "none"

echo "==> Disabling Automatic Text Substitutions..."

defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false

echo ""
echo "==============================================="
echo " Done!"
echo "==============================================="
echo ""
echo "Next steps:"
echo "  1. Restart your Mac"
echo "  2. Test login — unresponsiveness/sleep loop should be gone"
echo ""
read -p "Press Enter to close..."
