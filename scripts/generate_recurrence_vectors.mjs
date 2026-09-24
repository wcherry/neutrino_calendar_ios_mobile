#!/usr/bin/env node
//
// Regenerates NeutrinoCalendarTests/Fixtures/recurrence_vectors.json from the web client's own
// recurrence code, so the iOS expansion is tested against what the web actually does rather than
// against what someone believes it does.
//
//   scripts/generate_recurrence_vectors.mjs
//
// It reads `calendarHelpers.ts` from the sibling `neutrino` checkout, cuts out the RRULE block
// and `eventDayRange`, and runs them under Node's type stripping (Node 22.6+). The cut is by the
// section comments in that file, so a rename there fails loudly here instead of quietly testing
// stale code. Every case runs with TZ=America/Los_Angeles, which the Swift test pins too: the web
// expands in the viewer's local time, and a zone with a DST change is what makes that visible.
//
// Run it again whenever the web's recurrence code changes, and commit the JSON it writes.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const TZ = 'America/Los_Angeles';
const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..');
const helpers = join(repo, '..', 'neutrino', 'web', 'apps', 'web', 'src', 'app', '(apps)', 'calendar', 'calendarHelpers.ts');
const out = join(repo, 'NeutrinoCalendarTests', 'Fixtures', 'recurrence_vectors.json');

if (process.env.TZ !== TZ) {
  // The zone has to be set before the process starts; Date reads it once.
  execFileSync(process.execPath, [fileURLToPath(import.meta.url)], {
    env: { ...process.env, TZ }, stdio: 'inherit',
  });
  process.exit(0);
}

const source = readFileSync(helpers, 'utf8');
function cut(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  if (start < 0 || end < 0) throw new Error(`calendarHelpers.ts no longer contains ${startMarker} … ${endMarker}`);
  return source.slice(start, end);
}
const rrule = cut('// ── RRULE expansion', '// ── Multi-day events');
const days = cut('// ── Multi-day events', '/**\n * Pixel top and height');

const dir = mkdtempSync(join(tmpdir(), 'rrule-vectors-'));
const module = join(dir, 'helpers.ts');
// Both functions are already `export`ed in the source, so the cut is a module as it stands.
writeFileSync(module, `type EventResponse = any;\n${rrule}\n${days}\n`);
const { expandRecurringEvents, eventDayRange } = await import(module);

// ── Cases ────────────────────────────────────────────────────────────────────

const ev = (id, startTime, endTime, recurrenceRule = null, allDay = false) =>
  ({ id, title: id, startTime, endTime, allDay, recurrenceRule });

// US DST ends 2026-11-01 and begins 2027-03-14 in this zone.
const expansions = [
  ['not recurring passes through', ev('single', '2026-10-05T16:00:00Z', '2026-10-05T17:00:00Z'), '2026-10-01T07:00:00Z', '2026-11-01T06:59:59Z'],
  ['daily keeps 09:00 local across the DST end', ev('daily-dst', '2026-10-28T16:00:00Z', '2026-10-28T16:30:00Z', 'FREQ=DAILY'), '2026-10-27T07:00:00Z', '2026-11-04T07:59:59Z'],
  ['weekly', ev('weekly', '2026-09-02T17:00:00Z', '2026-09-02T18:00:00Z', 'FREQ=WEEKLY'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['weekdays, as the web editor writes them', ev('weekdays', '2026-09-01T15:30:00Z', '2026-09-01T15:45:00Z', 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'), '2026-09-01T07:00:00Z', '2026-09-15T06:59:59Z'],
  ['BYDAY on a Wednesday start reaches forward only', ev('byday-forward', '2026-09-02T17:00:00Z', '2026-09-02T18:00:00Z', 'FREQ=WEEKLY;BYDAY=MO,WE'), '2026-09-01T07:00:00Z', '2026-09-20T06:59:59Z'],
  ['COUNT with BYDAY counts weeks, not occurrences', ev('count-byday', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'FREQ=WEEKLY;BYDAY=TU,TH;COUNT=2'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['COUNT', ev('count', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'FREQ=DAILY;COUNT=3'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['INTERVAL', ev('interval', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'FREQ=WEEKLY;INTERVAL=2'), '2026-09-01T07:00:00Z', '2026-11-01T06:59:59Z'],
  ['monthly from the 31st overflows instead of clamping', ev('monthly-31', '2027-01-31T18:00:00Z', '2027-01-31T19:00:00Z', 'FREQ=MONTHLY'), '2027-01-01T08:00:00Z', '2027-07-01T06:59:59Z'],
  ['yearly from Feb 29 overflows to Mar 1', ev('yearly-leap', '2028-02-29T18:00:00Z', '2028-02-29T19:00:00Z', 'FREQ=YEARLY'), '2028-01-01T08:00:00Z', '2031-12-31T07:59:59Z'],
  ['UNTIL as a UTC date-time', ev('until-utc', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'FREQ=DAILY;UNTIL=20260904T170000Z'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['UNTIL as a bare date is ignored', ev('until-date', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'FREQ=WEEKLY;UNTIL=20260910'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['an RRULE: prefix is not parsed', ev('prefixed', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'RRULE:FREQ=DAILY'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['an unknown FREQ is not parsed', ev('hourly', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'FREQ=HOURLY'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['lowercase keys are accepted', ev('lowercase', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z', 'freq=DAILY;count=2'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['only occurrences starting inside the range', ev('mid-range', '2026-08-25T17:00:00Z', '2026-08-25T18:00:00Z', 'FREQ=DAILY'), '2026-09-10T07:00:00Z', '2026-09-13T06:59:59Z'],
  ['a master over 1000 steps back yields nothing', ev('capped', '2023-01-01T17:00:00Z', '2023-01-01T18:00:00Z', 'FREQ=DAILY'), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['weekly all-day event', ev('allday-weekly', '2026-09-07T00:00:00Z', '2026-09-07T23:59:59Z', 'FREQ=WEEKLY', true), '2026-09-01T07:00:00Z', '2026-10-01T06:59:59Z'],
  ['monthly across the DST start', ev('monthly-dst', '2027-02-15T17:00:00Z', '2027-02-15T18:00:00Z', 'FREQ=MONTHLY'), '2027-02-01T08:00:00Z', '2027-05-01T06:59:59Z'],
].map(([name, event, from, to]) => ({
  name, event, from, to,
  occurrences: expandRecurringEvents([event], new Date(from), new Date(to))
    .map((o) => ({ startTime: o.startTime, endTime: o.endTime })),
}));

const pad = (n) => `${n}`.padStart(2, '0');
const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const dayRanges = [
  ['timed, one day', ev('t1', '2026-09-01T17:00:00Z', '2026-09-01T18:00:00Z')],
  ['timed, crossing local midnight', ev('t2', '2026-09-02T05:00:00Z', '2026-09-02T09:00:00Z')],
  ['timed, ending exactly at local midnight', ev('t3', '2026-09-01T17:00:00Z', '2026-09-02T07:00:00Z')],
  ['timed, UTC date differs from local date', ev('t4', '2026-09-02T03:00:00Z', '2026-09-02T04:00:00Z')],
  ['all-day as the web writes it', ev('a1', '2026-09-01T00:00:00Z', '2026-09-01T23:59:59Z', null, true)],
  ['all-day over three days', ev('a2', '2026-09-01T00:00:00Z', '2026-09-03T23:59:59Z', null, true)],
  ['all-day with an exclusive midnight end, as .ics writes it', ev('a3', '2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z', null, true)],
  ['end before start collapses to one day', ev('bad', '2026-09-05T17:00:00Z', '2026-09-04T17:00:00Z')],
].map(([name, event]) => {
  const { first, last } = eventDayRange(event);
  return { name, event, first: ymd(first), last: ymd(last) };
});

writeFileSync(out, JSON.stringify({
  generatedBy: 'scripts/generate_recurrence_vectors.mjs',
  source: 'neutrino/web/apps/web/src/app/(apps)/calendar/calendarHelpers.ts',
  timeZone: TZ,
  expansions,
  dayRanges,
}, null, 2) + '\n');
console.log(`wrote ${expansions.length} expansion and ${dayRanges.length} day-range vectors to ${out}`);
