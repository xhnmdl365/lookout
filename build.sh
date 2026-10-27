#!/bin/zsh
# Builds ClaudeTasks.app next to this script.
set -e
cd "$(dirname "$0")"
A=ClaudeTasks.app/Contents
mkdir -p $A/MacOS $A/Resources
swiftc -swift-version 5 -O -o $A/MacOS/ClaudeTasks Sources/*.swift
cp Info.plist $A/Info.plist
cp judge-prompt.md $A/Resources/
codesign --force -s - ClaudeTasks.app
