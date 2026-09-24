# Neutrino Calendar iOS — Features & Roadmap

Modelled on `neutrino_notes_ios_mobile/agent_docs/road_map.md`.

Like Notes, Calendar is a client of the Neutrino platform, not a standalone calendar app. It does
not invent its own authentication, storage or sync backend. The calendar backend already exists:
`neutrino/src/calendar/` (`/api/v1/calendar/*`) plus the web client at
`web/apps/web/src/app/(apps)/calendar/`. The iOS app should reach feature parity with that web
client first, then go further where iOS is stronger: notifications, widgets, Siri and the
system calendar.

The roadmap assumes:

* Reuse `NeutrinoShared` for account identity, OAuth/PKCE, the sign-in screens, the keyring
  and app lock.
* Reuse the existing `/api/v1/calendar` events, reminders, tasks, attachments and connections APIs.
* Reuse Neutrino Drive for attachments, as the web app already does (`DriveFilePicker`).
* Be fully compatible with the web version so users can move between devices.
* Follow the same phased approach, SwiftUI + XcodeGen layout, iOS 16 floor and test discipline as
  the Notes app.

⸻

## What the backend gives us today

Checked against `neutrino/src/calendar/` on 2026-09-24. This list decides what counts as client
work and what needs a server epic first.

| Area | Status | Notes |
|---|---|---|
| Events CRUD | ✅ | `GET/POST /events`, `GET/PUT/DELETE /events/{id}`. `from`/`to` range query, `allDay`, `location`, `timezone`, `attendees` (emails only) |
| Recurrence | ⚠️ | The server **stores** an RRULE string and nothing else. The web app expands it client-side (`calendarHelpers.ts`). There is no EXDATE, no per-occurrence override, and no "this and following" edit |
| Reminders | ✅ | CRUD, `linkedEventId`, `linkedTaskId`, `recurrenceRule`, `completed`. Completing a recurring reminder moves it to its next occurrence (server-side since Epic 12) |
| Tasks | ✅ | Lists, reorder, multi-list membership, schedule-to-event, attachments |
| Attachments | ✅ | Events and tasks, by Drive `file_id` |
| Connections | ⚠️ | Google and Outlook over OAuth, Apple over CalDAV with an app-specific password. Sync is **pull-only**, triggered by `POST /sync/trigger` |
| Reminder delivery | ❌ | `reminder_engine` only logs "REMINDER FIRED" and stamps `notified_at`. There is no email, push or APNs |
| ICS import/export | ❌ | Designed in `calendar-reminder-app.md` but not implemented |
| Change feed | ❌ | There is no calendar sync token or delta endpoint, and no calendar channel on the file-events relay |
| Sharing | ❌ | Events are single-owner. Attendees are stored but not invited or notified |
| OAuth client | ✅ | `neutrino-calendar-ios`, seeded by migration 00135 |
| Encryption | ⚠️ | Events are stored **plaintext** server-side, unlike Notes. See the open decisions below |

⸻

## Vision

**Phase 1 (MVP):** a secure, offline-capable calendar for your Neutrino account.

Users can:

* Sign in
* See their events, including events synced from Google, Outlook and iCloud
* Create, edit and delete events
* Get reminders on the device at the right time
* Read their calendar offline

**Phase 2:** a native iOS scheduling experience.

**Phase 3:** reminders and tasks at parity with web.

**Phase 4:** deep Apple ecosystem integration.

**Phase 5:** collaboration and scheduling across accounts.

⸻

## Architecture

### Existing Neutrino services

Reuse:

* Authentication (`NeutrinoAuth`)
* Calendar APIs (`/api/v1/calendar`)
* Drive APIs (attachments)
* Key management (`NeutrinoCrypto`), if events become E2EE
* Search APIs

The Calendar app should not maintain a separate backend.

### iOS components

**SwiftUI application.** Authentication, UI, the calendar views, the event editor and navigation.

**Local store.** Events, reminders, tasks, connection metadata and a sync queue. It keeps a range
window, for example 3 months back and 12 months ahead, rather than all of history.

**Recurrence engine.** RRULE expansion on the device (`RecurrenceExpander`). It agrees with the
web's `calendarHelpers.ts` expansion case for case, pinned by vectors generated from the web's
own code; see Epic 3 for where both depart from RFC 5545.

**Sync engine.** Range pulls, a queued offline write-back, conflict detection on `updatedAt`, and
background refresh.

**Notification scheduler.** Schedules local notifications with `UNUserNotificationCenter` from the
synced reminders and event alerts. The server can't push yet, so the device has to be the alarm.

### New platform touchpoints

Each of these follows a coupling rule in the root `CLAUDE.md`:

* ✅ Migration seeding the OAuth client `neutrino-calendar-ios` (rule 3)
* ✅ `NeutrinoAppConfig.calendar` in `neutrino_shared_ios` with the Keychain prefix `ncal`, added
  to `allApps` (rules 2 and 4)
* Universal Links `https://www.getneutrino.app/open/event/<id>` added to the
  apple-app-site-association document in the Drive repository

⸻

## Phase 1 — Core Platform

Goal: a secure shell connected to the Neutrino calendar.

### ✅ Epic 1 — Application Shell

Features

* ✅ SwiftUI app scaffolded from the Notes `project.yml` (bundle id `com.neutrino.calendar`)
* ✅ Tab navigation: Calendar · Reminders · Tasks · Settings
* ✅ Settings (server, version, the "Report a Bug" button from Notes, Sign Out)
* ✅ Empty states
* ✅ Brand (purple into pink, `calendar` symbol) and home-screen name "Calendar"
* ✅ App icon artwork: the brand's purple-into-pink gradient with the `calendar` symbol, in the
  same geometry as the Notes and Slides icons (full bleed, no alpha, mark 558 px of 1024)

Milestone

The app launches with navigation and empty states.

⸻

### ✅ Epic 2 — Authentication

Reuse the `NeutrinoShared` flow unchanged.

Features

* ✅ `neutrino-calendar-ios` OAuth client (`neutrino/migrations/00135_oauth__*`)
* ✅ `NeutrinoAppConfig.calendar` + `NeutrinoBrand.calendar` in the shared package, in `allApps`
  so the collision tests cover them. The brand's sign-in rows don't claim end-to-end encryption,
  because events are stored readable on the server
* ✅ Login, refresh tokens, logout, session persistence, all wired through `NeutrinoShared`
* ✅ Shared keyring access group, so a key imported in another Neutrino app is already present

Milestone

Users stay signed in after the app restarts, and co-installed Neutrino apps keep separate sessions.

⸻

### ✅ Epic 3 — Calendar Read

Features

* ✅ Fetch events by range (`GET /api/v1/calendar/events?from&to`), a month at a time over the
  web's own `monthRange`, so an occurrence near a month boundary lands on the same side in both
* ✅ Client-side RRULE expansion (DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL, BYDAY):
  `RecurrenceExpander`, a port of the web's `expandRecurringEvents`, quirks included (below)
* ✅ Time-zone-correct display: times in the device's zone, plus the event's own zone when it
  differs ("2:00 PM – 3:00 PM Eastern Time")
* ✅ All-day events, as dates rather than instants, on every day they cover (`EventDayRange`)
* ✅ Events from connected providers, badged by `source` (Google, Outlook, iCloud)
* ✅ Event detail: time, location, notes, guests, attachments (listed; opening a Drive file is
  Epic 14)
* ✅ A month agenda (the web's Agenda view) that opens at today; Month/Week/Day grids are Epic 5

Parity is enforced, not hoped for: `scripts/generate_recurrence_vectors.mjs` runs the web's
`calendarHelpers.ts` and writes `NeutrinoCalendarTests/Fixtures/recurrence_vectors.json`, and
`RecurrenceVectorTests` holds the Swift port to it. Regenerate after any change to the web's
recurrence code.

**Where both clients depart from RFC 5545.** Kept on purpose for now, since the two clients have
to agree, and each one is a web bug to fix in both places at once:

* ⬜ COUNT counts FREQ steps, not occurrences: `FREQ=WEEKLY;BYDAY=TU,TH;COUNT=2` shows four
* ⬜ A date-only UNTIL (`UNTIL=20260930`) is ignored, so the event repeats forever
* ⬜ MONTHLY/YEARLY overflow instead of skipping: Jan 31 → Mar 3, and every later month keeps
  the 3rd
* ⬜ A rule with an `RRULE:` prefix doesn't parse, and the event shows once
* ⬜ Expansion stops 1000 steps after the first occurrence: a daily event begun three years ago
  shows nothing
* ⬜ A repetition that starts before the range is not shown, even while it is still running inside it (one-off events are fine: the server returns every event that overlaps)

Milestone

What a user sees on the phone matches the web calendar for the same range.

⸻

### ⬜ Epic 4 — Event Editing

Features

* ⬜ Create event (title, start/end, all-day, location, description)
* ⬜ Edit and delete event
* ⬜ Repeat picker that writes an RRULE the web understands
* ⬜ Time-zone picker
* ⬜ Attendees (email list — stored only, see Epic 18)
* ⬜ Read-only handling for provider-sourced events until write-back exists (Epic 17)

Milestone

Events created on the phone appear correctly on the web, and events created on the web appear
correctly on the phone.

⸻

## Phase 2 — Native Scheduling Experience

Goal: a calendar that feels native on iOS.

### ⬜ Epic 5 — Views

* ⬜ Month (with event dots, in the style of iPhone Calendar)
* ⬜ Week (time grid)
* ⬜ Day (time grid)
* ⬜ Agenda (parity with the web `AgendaView`)
* ⬜ Year overview
* ⬜ Jump to today, and a date picker to jump to any date
* ⬜ Current-time indicator

Milestone

The same three views as web, plus Day and Year.

⸻

### ⬜ Epic 6 — Direct Manipulation

* ⬜ Tap-and-drag on the time grid to create
* ⬜ Drag to move and drag-resize to change duration
* ⬜ Swipe between days, weeks and months
* ⬜ Haptics on snap

⸻

### ⬜ Epic 7 — Quick Entry

* ⬜ Natural-language entry ("Dinner tomorrow at 7"), parsed on the device with `NSDataDetector`
  plus light rules, not by a server call
* ⬜ Default duration and default alert settings

⸻

### ⬜ Epic 8 — iPad

* ⬜ Sidebar + detail layout
* ⬜ Keyboard shortcuts (⌘N, ⌘T, arrow navigation)
* ⬜ Multi-window and Stage Manager

⸻

## Phase 3 — Sync, Offline & Alerts

Goal: dependable on the move.

### ⬜ Epic 9 — Offline Store

* ⬜ Cache a rolling range window
* ⬜ Read offline
* ⬜ Create, edit and delete offline through a queued write-back
* ⬜ Sync when connectivity returns (reuse the `NetworkMonitor` pattern from Notes)

Milestone

Offline behaviour matches Notes: every edit is queued, none is lost, and conflicts are shown to
the user rather than resolved silently.

⸻

### ⬜ Epic 10 — Sync Engine

* ⬜ Background refresh (`BGAppRefreshTask`)
* ⬜ Conflict detection on `updatedAt`
* ⬜ Retry queue
* ⬜ Pull-to-refresh that also calls `POST /sync/trigger` for connected providers
* ⬜ **Backend:** a delta endpoint (`GET /events/changes?since=`) so the client stops re-pulling
  whole ranges
* ⬜ **Backend:** a calendar channel on the file-events relay for live updates, as Notes has

⸻

### ⬜ Epic 11 — Alerts & Notifications

* ⬜ Per-event alerts (at time, 5/10/15/30 min, 1 h, 1 day before, custom)
* ⬜ Local notifications scheduled from synced reminders and alerts, re-planned after each sync.
  iOS limits an app to 64 pending notifications, so schedule the nearest ones first
* ⬜ Notification actions: Snooze, Mark done, Open
* ⬜ Stamp completion back to the server (`PATCH /reminders/{id}`)
* ⬜ **Backend (later):** real delivery in `reminder_engine` (APNs device-token registration +
  push), so alerts fire on a device that hasn't synced recently. This is a platform-wide epic,
  because no Neutrino app has push today

Milestone

A reminder set on the web fires on the phone at the right time, including with the app closed.

⸻

## Phase 4 — Reminders & Tasks

Goal: parity with the web sidebars.

### ✅ Epic 12 — Reminders

* ✅ List, create, edit, complete and delete (Reminders tab, `ReminderEditorView`, swipe to
  delete)
* ✅ Recurring reminders: Never / Daily / Weekdays / Weekly / Monthly / Yearly, and a rule
  written elsewhere is kept as it is. **Completing one moves it to its next occurrence on the
  server** (`neutrino/src/calendar/recurrence.rs`), stepped in the zone the client sends, so the
  web and iOS behave the same. COUNT counts down on each completion, and the reminder is done
  when the rule runs out
* ✅ Link to an event (the event's Reminders section, with the web's presets from "At time of
  event" to "1 week before", plus Custom) or to a task (picked when creating). Links are set at
  creation only, because the server's update has no link fields
* ✅ The web's Today / 3 days / 7 days / All filter, with overdue reminders in every range, plus
  search, and completed reminders listed after open ones
* ⬜ Web: the reminder form has no repeat field, so a repeating reminder can only be *made* on
  iOS or through the API. It completes correctly on the web
* ⬜ Web: the sidebar lists only unlinked reminders. The iOS tab lists every reminder, since it is
  the only list a phone has; decide whether the web should follow

⸻

### ⬜ Epic 13 — Tasks

* ⬜ Task lists (create, color, rename)
* ⬜ Tasks: title, notes, due date, done
* ⬜ Reorder by drag (`POST /tasks/reorder`)
* ⬜ A task in several lists
* ⬜ Schedule a task as an event (`POST /tasks/{id}/event`), and unschedule it
* ⬜ Task attachments

⸻

### ⬜ Epic 14 — Attachments

* ⬜ Attach a Drive file to an event or task (a Drive picker like web's `DriveFilePicker`)
* ⬜ Upload from Photos or Files, then attach
* ⬜ Preview with Quick Look and decrypt E2EE Drive files on the device (reuse `NeutrinoCrypto`)
* ⬜ Open in Drive, Docs, Sheets or Notes through Universal Links

⸻

## Phase 5 — Apple Ecosystem

Goal: Calendar shows up everywhere iOS shows a calendar.

### ⬜ Epic 15 — Widgets & Live Activities

* ⬜ Home Screen widgets: Up Next, Today, Month
* ⬜ Lock Screen widgets
* ⬜ Live Activity for an event in progress, and a countdown to the next one
* ⬜ An App Group snapshot for widgets. It must contain the rendered next-N events only, never
  tokens

⸻

### ⬜ Epic 16 — Siri, Shortcuts & Spotlight

* ⬜ App Intents: "What's next", "Add event", "Add reminder"
* ⬜ Spotlight indexing of upcoming events
* ⬜ Focus filters (show only selected calendars)

⸻

### ⬜ Epic 17 — Provider Connections

* ⬜ Manage connections in Settings: Google and Outlook through `ASWebAuthenticationSession`,
  Apple through CalDAV with an app-specific password
* ⬜ Disconnect
* ⬜ Per-connection visibility and color
* ⬜ **Backend:** two-way sync. Today it is pull-only, so provider events stay read-only on the
  device until this exists

⸻

### ⬜ Epic 18 — ICS & System Calendar

* ⬜ Open `.ics` files and invites from Mail or Files (a document type, like the Notes key-file
  type)
* ⬜ Share an event as `.ics`
* ⬜ **Backend:** `POST /events/import-ics`, `GET /events/export-ics` (designed, not built)
* ⬜ Optional one-way mirror into EventKit so events show in the system Calendar and CarPlay.
  This is opt-in and off by default, because it copies Neutrino data into iCloud

⸻

## Phase 6 — Collaboration

Reuse Neutrino's sharing model.

### ⬜ Epic 19 — Invitations

* ⬜ Invite Neutrino users (directory lookup, as the Notes share sheet does)
* ⬜ RSVP: accept, tentative or decline
* ⬜ Email invites to external attendees (iMIP)
* ⬜ **Backend:** attendee status, notifications, invite delivery. Only emails are stored today

⸻

### ⬜ Epic 20 — Shared Calendars & Availability

* ⬜ Share a calendar with viewer or editor roles
* ⬜ Free/busy lookup when scheduling
* ⬜ Team calendars (ties into `team-spaces.md`)

⸻

### ⬜ Epic 21 — Recurrence Exceptions

* ⬜ Edit or delete "this event", "this and following" or "all events"
* ⬜ **Backend:** EXDATE and occurrence-override storage. This is the biggest server gap, and web
  needs it too

⸻

## Phase 7 — Polish

* ⬜ Face ID / Touch ID lock (reuse `AppLockService` and `LockScreenView` from Notes, or better,
  promote them into `NeutrinoUI`)
* ⬜ Search (title, location, description, attendees; offline over the local store)
* ⬜ Week-start preference, 24 h clock, week numbers, alternate calendars
* ⬜ Travel time and "leave now" alerts (MapKit ETA)
* ⬜ Handoff to the web calendar
* ⬜ Drag & drop (a Drive file onto an event, a task onto the time grid)
* ⬜ Accessibility: VoiceOver on the time grid, Dynamic Type
* ⬜ Localization, including right-to-left languages and locale-specific first day of the week
* ⬜ Performance: 10k events, deep recurrence

⸻

## Open decisions (resolve before Phase 1 starts)

1. **Encrypt events end to end?** Notes, Drive and every file are E2EE, but calendar rows are
   plaintext on the server. Encrypting title, description and location would match the platform's
   privacy promise. It would also break server-side reminder delivery text, search, and any
   provider write-back, because Google and Outlook have to see the plaintext. A likely middle
   ground is E2EE for native `local` events, with provider-synced events left plaintext. Either
   way it is a wire-format change across the server, web and iOS (root `CLAUDE.md` rule 5), so
   decide it before the iOS client hard-codes the current shape.
2. **Where RRULE expansion lives.** It could stay on the client (web and iOS each implement it,
   pinned by shared test vectors) or move to the server (`GET /events` returns occurrences).
   Recurrence exceptions (Epic 21) push towards the server.
3. **Push infrastructure.** Local notifications are enough for the MVP. APNs is a platform-wide
   investment that every Neutrino app would benefit from.
4. **Mirroring into EventKit.** It is convenient, but it copies data out of Neutrino's trust
   boundary.

⸻

## MVP success criteria

The MVP is complete when a user can:

* ⬜ Log in with the existing Neutrino authentication flow
* ⬜ See all their events, native and provider-synced, in Month, Week, Day and Agenda views
* ⬜ Create, edit and delete events, including simple recurring events, and see them identically
  on web
* ⬜ Receive on-device alerts for events and reminders, including with the app closed
* ⬜ Read their calendar offline and have offline edits sync when connectivity returns
* ⬜ Manage reminders and tasks at parity with the web sidebars

### Suggested sequencing

| Milestone | Epics | Backend dependency |
|---|---|---|
| M1 — Shell & sign-in | 1, 2 | OAuth client migration, shared-package config |
| M2 — Read-only calendar | 3, 5 | none |
| M3 — Editing | 4, 6, 7 | none |
| M4 — Offline & alerts (MVP) | 9, 10, 11 | a delta endpoint is useful but not blocking |
| M5 — Reminders, tasks, attachments | 12, 13, 14 | none |
| M6 — Apple ecosystem | 8, 15, 16, 17, 18 | ICS endpoints, two-way sync |
| M7 — Collaboration | 19, 20, 21 | invites, sharing, recurrence exceptions |
