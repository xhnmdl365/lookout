#!/bin/zsh
# Builds TaskFloat.app next to this script.
set -e
cd "$(dirname "$0")"
A=TaskFloat.app/Contents
mkdir -p $A/MacOS $A/Resources
swiftc -swift-version 5 -O -o $A/MacOS/TaskFloat main.swift
cp Info.plist $A/Info.plist
cp judge-prompt.md $A/Resources/
codesign --force -s - TaskFloat.app
