#!/bin/sh
# Runs the package's tests with only Apple's Command Line Tools installed (no Xcode): Swift Testing is
# there, but outside SwiftPM's search path, and its Foundation overlay ships without a module (so the
# test targets build without cross-import overlays: see Package.swift).
# With Xcode installed, plain `swift test` works.
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$F/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  MESHCHAT_CLT_TESTING=1 exec swift test -Xswiftc -F -Xswiftc $F \
    -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
fi
exec swift test "$@"
