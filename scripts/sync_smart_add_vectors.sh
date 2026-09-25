#!/bin/sh
#
# Copies the web's Smart Add fixture table into this app's test bundle, so `SmartAdd.swift` is
# tested against exactly the cases `smartAdd.ts` is. The web's copy is the source of truth: add a
# case there, run this, and commit the JSON it writes.
#
#   scripts/sync_smart_add_vectors.sh
#
# `SmartAddTests.testFixtureIsTheWebsCopy` fails while the two differ, whenever the sibling
# `neutrino` checkout is present.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../neutrino/web/apps/web/src/app/(apps)/calendar/smartAddFixtures.json"
dst="$here/../NeutrinoCalendarTests/Fixtures/smart_add_vectors.json"
cp "$src" "$dst"
echo "Copied $(basename "$src") → NeutrinoCalendarTests/Fixtures/$(basename "$dst")"
