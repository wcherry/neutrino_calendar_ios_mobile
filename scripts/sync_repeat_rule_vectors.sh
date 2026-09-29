#!/bin/sh
#
# Copies the web's repeat-rule fixture table into this app's test bundle, so `RepeatRule.swift` is
# tested against exactly the cases `repeatRule.ts` is. The web's copy is the source of truth: add a
# case there, run this, and commit the JSON it writes.
#
#   scripts/sync_repeat_rule_vectors.sh
#
# `RepeatRuleTests.testFixtureIsTheWebsCopy` fails while the two differ, whenever the sibling
# `neutrino` checkout is present.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../neutrino/web/apps/web/src/app/(apps)/calendar/repeatRuleFixtures.json"
dst="$here/../NeutrinoCalendarTests/Fixtures/repeat_rule_vectors.json"
cp "$src" "$dst"
echo "Copied $(basename "$src") → NeutrinoCalendarTests/Fixtures/$(basename "$dst")"
