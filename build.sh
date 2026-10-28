#!/bin/zsh
# Builds Lookout.app next to this script.
set -e
cd "$(dirname "$0")"
A=Lookout.app/Contents
mkdir -p $A/MacOS $A/Resources
swiftc -swift-version 5 -O -o $A/MacOS/Lookout Sources/*.swift
cp Info.plist $A/Info.plist
cp judge-prompt.md $A/Resources/
codesign --force -s - Lookout.app
