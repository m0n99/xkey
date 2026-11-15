#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build/headless-browser-registry
swiftc \
    Shared/SharedBrowserRegistry.swift \
    Tools/headless-browser-registry/StubSharedSettings.swift \
    Tools/headless-browser-registry/ConcurrentReloadScenarios.swift \
    Tools/headless-browser-registry/main.swift \
    -o build/headless-browser-registry/run
exec build/headless-browser-registry/run
