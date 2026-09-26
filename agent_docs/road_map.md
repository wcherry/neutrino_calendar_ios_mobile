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
* ✅ Event detail: time, location, notes, guests, attachments (opened and added since Epic 14)
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

### ✅ Epic 4 — Event Editing

Features

* ✅ Create event (title, start/end, all-day, location, notes) from the Calendar tab's +, on the
  day in view: the next hour today, 09:00 on other days, for an hour
* ✅ Edit and delete event, from its detail screen. A one-off event's screen follows the edit;
  a repeating one's closes, since the series has moved
* ✅ Repeat picker that writes the RRULEs the web writes, and keeps one it has no choice for
* ✅ Time-zone picker. Times are entered in the chosen zone, and picking a zone keeps the clock
  times (10:00 stays 10:00, now in New York), as the iPhone's Calendar does
* ✅ Attendees (an email list; stored only, see Epic 19)
* ✅ Read-only handling for provider-sourced events until write-back exists (Epic 17): no Edit
  button, and a line saying where to edit it
* A repeating event is edited and deleted as a whole series, from the series' own start. Editing
  or deleting one occurrence needs recurrence exceptions (Epic 21)
* ⬜ Reminders and attachments while creating, as the web's form offers: on iOS they are added
  from the event's screen once it exists
* ⬜ Web: a field cleared in the event form (location, notes, repeat) is sent as `null`, which the
  server reads as "leave alone", so it keeps its old value. iOS sends `""`
* ⬜ Web: editing an occurrence of a repeating event saves that occurrence's date as the series'
  start, dropping every earlier occurrence. iOS edits from the series' own start
* ⬜ Web: events synced from Google, Outlook or iCloud can be edited there, though the change
  never reaches the provider

Milestone

Events created on the phone appear correctly on the web, and events created on the web appear
correctly on the phone.

⸻

## Phase 2 — Native Scheduling Experience

Goal: a calendar that feels native on iOS.

### ✅ Epic 5 — Views

* ✅ Month: a grid with a dot per event (up to three) and the selected day's events below, as
  the iPhone's Calendar shows a month; swipe the grid for the next or previous month
* ✅ Week: seven columns over a 24-hour grid, an all-day row above it, and tapping a day's header
  opens that day
* ✅ Day: one column over the same grid, with times on each block
* ✅ Agenda: parity with the web's `AgendaView` (from Epic 3)
* ✅ Year: twelve small months; tap one to open it
* ✅ Jump to today, and the title opens a calendar to jump to any date
* ✅ Current-time indicator: a red line across today's column, moved every minute
* The grid follows the web's: 24 hours with 08:00–20:00 at full strength, at least 24 minutes
  tall per block, and a multi-day timed event filling each day in between. Unlike the web,
  overlapping events sit side by side (`TimeGridLayout`). The grid opens an hour before now on
  a day that includes today, and at 08:00 otherwise
* Events load a month at a time over the web's `monthRange`, and loaded months are kept, so
  switching views over the same dates costs no requests; a week across a month end loads both
  months. The chosen view is remembered per device (`ncal.calendar.mode`)
* ⬜ Web: the week view loads only the cursor's month, so a week across a month end misses the
  other month's events there

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

### ✅ Epic 10 — Sync Engine

* ✅ **Backend:** events are soft-deleted (`deleted_at`, migration 00137). Every read skips
  deleted rows; the tombstones are kept for 90 days, then a daily job purges them
* ✅ **Backend:** a delta endpoint, `GET /events/changes?since=`: the events changed and the ids
  deleted since a cursor. With no `since`, it answers only a cursor to start from. A cursor
  older than the tombstones answers `fullResyncRequired`
* ✅ **Backend:** a live `calendar.changed` signal on the per-user notification socket (the one
  `drive.changed` uses), after any successful write under `/api/v1/calendar`. It carries the
  writer's `X-Neutrino-Client-Id`, so a client can skip the echo of its own writes. The web
  now drops any signal it doesn't use, instead of showing it as a notification
* ✅ Loaded months are kept up to date from the changes feed: on a live signal, when the socket
  reconnects, when the app comes forward, and from background refresh. Changed events are
  merged into each loaded month by the server's own range test, and the months are expanded
  again. Reminders and tasks are small whole lists, so they are reloaded
* ✅ Conflict detection: before saving an event, reminder or task edit, the server's copy is
  read. The save stops only if the thing was deleted, or one of the *same* fields was changed
  to something else elsewhere (edits send only what changed, so other fields can't be
  overwritten). The alert offers Save Mine Anyway or Discard My Changes. `updatedAt` isn't used
  because a provider sync bumps it without changing anything
* ✅ Retry queue: an edit, completion or delete that fails because the network is down is
  queued (saved to a file, so it survives a relaunch) and shown at once. It replays in order
  when the network comes back, on reconnect, on foreground, and from background refresh. A 404
  or other 4xx is dropped; a 5xx is retried up to five times. A "changes waiting to sync"
  banner shows while writes are queued. Creates aren't queued, because replaying one could
  make a duplicate
* ✅ Pull-to-refresh calls `POST /sync/trigger` for the connected providers first
* ✅ Background refresh (`BGAppRefreshTask`) replays the queue and pulls changes as well as
  re-planning alerts

⸻

### ✅ Epic 11 — Alerts & Notifications

* ✅ Per-event alerts: an event's alert is a reminder linked to it (the presets from "At time of
  event" to "1 week before", Epic 12), so it alerts like any other reminder
* ✅ Local notifications scheduled from synced reminders, re-planned whenever the list changes,
  when the app comes forward, and from background refresh (`BGAppRefreshTask`, about every half
  hour, as iOS allows). The nearest 60 are scheduled, under iOS's 64, and the rest follow as
  those fire. A moved reminder replaces its notification. Nothing is re-planned from a list that
  hasn't loaded, so a launch with no network keeps the alerts already scheduled
* ✅ Notification actions: Mark as Done, Snooze 10 Minutes (this device only), and tapping opens
  the reminder in the Reminders tab
* ✅ Mark as Done completes the reminder on the server (`PATCH /reminders/{id}` with the device's
  zone), which moves a repeating one to its next time
* ✅ Settings › Notifications: a Reminder alerts switch, and a way to Settings if notifications
  were refused. Permission is asked the first time there is a reminder to alert about
* ⬜ **Backend (later):** real delivery in `reminder_engine` (APNs device-token registration +
  push), so alerts fire on a device that hasn't synced since the reminder was set. This is a
  platform-wide epic, because no Neutrino app has push today

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
* ✅ Web: the reminder form has the same repeat choices as the event form (`REPEAT_OPTIONS`),
  and keeps a rule it has no choice for rather than rewriting it
* ✅ Web: the sidebar lists every reminder, as the iOS tab does, labelling the ones that belong to
  an event or a task and marking the repeating ones

⸻

### ✅ Epic 13 — Tasks

* ✅ Tasks: title, notes, due date, done. A due date is a day, the same in every zone
* ✅ Type a task and press return to add it; the box stays focused for the next one
* ✅ Reorder by drag (Edit, then drag; `POST /tasks/reorder` with the open tasks' order)
* ✅ Schedule a task as an event, and unschedule it: "Add to calendar" with a start and end or
  all day. It starts at 09:00 on the due day or the next hour, for an hour, and an already
  scheduled task opens on its event's real slot so opening it never moves anything
* ✅ The task's reminders (add one prefilled with the task's title) and note attachments
* ✖ Task lists (create, color, rename) and a task in several lists: **dropped**. The web
  stopped grouping by lists because they are being replaced by tags, so tasks are one flat
  list in the server's order on both clients. Revisit when tags reach tasks
* ✅ Attach a Drive file to a task (Epic 14)
* ⬜ Delete a task. The server has no route for it, and the web can't either
* ⬜ Add tasks from a `.txt` or `.csv` file, as the web can

⸻

### ✅ Epic 14 — Attachments

* ✅ Attach a Drive file to an event or task, with a Drive picker like the web's `DriveFilePicker`
  (folders, filter by name). Events and tasks share one attachments section, notes included
* ✅ Add from Photos or Files. The file is encrypted on the phone and uploaded into Drive's
  "Attachments" folder, the one the web uses, then attached. Like the web, it never falls back to
  uploading in the clear. If its key can't be stored, the upload is removed rather than left
  unreadable
* ✅ Preview with Quick Look. The file is decrypted on the device with the account key and cached
  under its content version (complete file protection; cleared on sign-out). Files stored in the
  clear before encryption open as they are. The crypto is `DriveFileCrypto`, added to
  `NeutrinoCrypto`; tests show files written by the web's `crypto.ts` open here and vice versa
* ✅ Open in Docs, Sheets, Slides, Notes or Drive through Universal Links (`NeutrinoAppLink`,
  universal links only). If the app isn't installed, the file can be previewed here instead
* ✅ Settings › Encryption: the key comes from the keyring the Neutrino apps share, or from this
  app's own store. Without one, the section offers setting up encryption, pairing with another
  device, or restoring from a recovery kit

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
* ✅ Compact layout: a Settings switch for tighter rows, section gaps and screen margins (off
  by default; the section gaps and margins need iOS 17)
* ✅ Week-start preference: Sunday, Monday or Saturday, the web's choices and default (Sunday),
  stored as the web stores it (a JavaScript day number) under `ncal.calendar.weekStart`
* ⬜ 24 h clock, week numbers, alternate calendars
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
| M5 — Reminders, tasks, attachments | 12, 13, 14 | a delete route for tasks |
| M6 — Apple ecosystem | 8, 15, 16, 17, 18 | ICS endpoints, two-way sync |
| M7 — Collaboration | 19, 20, 21 | invites, sharing, recurrence exceptions |
