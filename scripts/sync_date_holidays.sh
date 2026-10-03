#!/bin/sh
#
# Copies the `date-holidays` bundle the web uses into the app, so holiday calendars compute the
# same days on iOS as on the web: the same rules, the same version. The web's lockfile is the
# source of truth. Run this after the web upgrades date-holidays, and commit what it writes.
#
#   scripts/sync_date_holidays.sh
#
# The bundle is the package's own self-contained UMD build (rules data included), run on the
# device by JavaScriptCore; see NeutrinoCalendar/Services/HolidayEngine.swift. The code is ISC
# and the rules data CC BY-SA 3.0; both licences are copied beside it.
# `HolidayEngineTests.testBundleIsTheWebsVersion` fails while the two differ, whenever the
# sibling `neutrino` checkout is present.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
web="$here/../../neutrino/web/apps/web"
pkg=$(cd "$web" && node -e "console.log(require('path').dirname(require.resolve('date-holidays/package.json')))")
dst="$here/../NeutrinoCalendar/Resources/DateHolidays"
mkdir -p "$dst"
cp "$pkg/dist/umd.min.js" "$dst/date-holidays.umd.min.js"
cp "$pkg/LICENSE" "$dst/LICENSE.txt"
cp "$pkg/dist/umd.min.js.LICENSE.txt" "$dst/THIRD-PARTY-LICENSES.txt"
version=$(node -e "console.log(require('$pkg/package.json').version)")
printf '%s\n' "$version" > "$dst/VERSION"
echo "Copied date-holidays $version → NeutrinoCalendar/Resources/DateHolidays"
