# Task geofencing: arrival reminders, saved places, Nearby

Issue: wcherry/neutrino_calendar_ios_mobile#23 (this app). The server, web and TypeScript
envelope work is wcherry/neutrino#243. Branch `feature/task-geofencing` in every repo.

A task can remind you when you **arrive** at a place: one of your saved places ("Home", "Work",
"Safeway on 5th") or a one-off point. iOS watches for the arrival on the device and posts a local
notification. The server never learns where you are, and it can't read your saved places.

## Data

| Where | What | Encrypted |
|---|---|---|
| `task_places` | `id`, `user_id`, `encrypted_payload`, timestamps | **Yes**: payload is a `PlaceEnvelope` |
| `tasks.geo_place_id` | FK to `task_places`, `ON DELETE SET NULL` | No (an id) |
| `tasks.geo_lat` / `geo_lng` / `geo_radius_m` | a one-off point | No, on purpose |
| `tasks.location` | the text shown (Smart Add's `@Safeway`, or the place picked) | No, as before |

A task uses either a place or a point, never both. `UpdateTaskRequest.setGeofence` sends all four
fields whenever the geofence changes, so one kind always clears the other. An edit that doesn't
touch the place sends none of them. That keeps older clients' edits from dropping a geofence.

### API (contract for wcherry/neutrino#243)

```
GET    /api/v1/calendar/task-places        → { places: [{ id, encryptedPayload, createdAt, updatedAt }] }
POST   /api/v1/calendar/task-places        { encryptedPayload } → 201 place
PATCH  /api/v1/calendar/task-places/{id}   { encryptedPayload } → place
DELETE /api/v1/calendar/task-places/{id}   → 204; clears geo_place_id on its tasks
Task DTOs: geoPlaceId, geoLat, geoLng, geoRadiusM (optional; null clears on PATCH)
```

Until the server has these routes, `GET /task-places` answers 404. `PlacesService` then sets
`isSupported = false`, and the app hides saved places and offers one-off points only. An older
server ignores the task fields it doesn't know.

## The envelope (`PlaceEnvelope`, v1)

This is the first end-to-end encrypted data in Calendar. It is built only from primitives every
client already shares with Drive files, so the web needs no new cryptography:

```
encryptedPayload = JSON { "v": 1, "keyVersion": <int>, "key": <string>, "data": <string> }
  dek  = 32 random bytes, fresh per write            (web: generateFileKey · Swift: DriveFileCrypto.newDEK)
  key  = crypto_box_seal(dek, account public key)     (web: encryptFileKey  · Swift: DriveFileCrypto.seal)
         base64url, no padding
  data = one crypto_secretstream_xchacha20poly1305    (web: encryptMetadata · Swift: DriveFileCrypto.encrypt)
         push of the payload JSON, TAG_FINAL, header-prefixed, base64url no padding
payload = JSON { "name": String, "lat": Double, "lng": Double, "radiusM": Int }
```

- `keyVersion` is the keyring version the DEK was sealed to (the active one when written). A
  reader looks up that version, which may be a retired key after a rotation.
- A reader rejects any `v` other than 1 and ignores payload fields it doesn't know.
- A place this device can't open (no key yet, or a missing key version) is counted in
  `PlacesService.unreadable`, not shown, and its tasks aren't watched. The UI says why.

**Fixture.** `place_envelope_vectors.json` is generated from the web's own `crypto.ts` by
`neutrino_shared_ios/scripts/generate_place_envelope_vectors.mjs`, into that package's
`Tests/NeutrinoCryptoTests/Fixtures/`. `PlaceEnvelopeTests` there opens every case, and the web's
`e2e-crypto` tests open a byte-identical copy. Changing anything above is a wire-format change across
the web, every iOS app and the server.

**Where it lives.** `PlaceEnvelope` is in `NeutrinoCrypto` (`neutrino_shared_ios`), next to the
`DriveFileCrypto` primitives it is built from, so any app can read saved places. This app keeps the
models around it (`Models/TaskPlace.swift`) and `PlacesService`, which seals and opens with it.

## Watching for arrivals (`GeofenceMonitor`)

- **Region monitoring** with `CLLocationManager` (`CLCircularRegion`, entry only). iOS allows 20
  regions per app. `GeofencePlan.candidates` makes one region per saved place, however many tasks
  use it, plus one per one-off point, from the **open** tasks only.
  `GeofencePlan.nearest` picks the 20 whose edge is nearest the device. Region ids start with
  `ncal.geo.`, so the app never touches anyone else's.
- **Re-picking.** This happens when the tasks or places change (a sync, a completion, a
  deletion), once both have loaded. Planning from a list that hasn't loaded yet would stop every
  alert. With more than 20 candidates, significant location changes are watched too, and each one
  re-picks the nearest 20. With 20 or fewer they're off, to save battery.
- **Background and terminated.** iOS relaunches the app to report an arrival. The manager's
  delegate is set during launch (`AppServices`), and the candidates are kept in
  `Application Support/geofences.json` with their task titles, protected until first unlock. So an
  arrival can be announced before anything has loaded. A task already known to be done is
  skipped.
- **Alert.** One notification per open task at the place: the task's title, "You're at <place>",
  category `TASK_ARRIVAL` with **Mark as Done**. Tapping it opens the task. It fires once per
  arrival (iOS reports entry once until exit), and completing the task removes it from the plan.
  The Settings › Reminder alerts switch turns these off too.
- **Owner.** Tasks have no assignee, so the alert goes to the owner's devices. If assignees arrive,
  the alert should follow the assignee.

### Permission

The app asks in context:

1. **When In Use**, when the place picker opens or Nearby is turned on.
2. **Always**, when a task gets its first place (picked in the editor, or `@Home` in Smart Add).
   iOS shows this upgrade once. After that, the editor's footer explains what's missing and links
   to Settings.

Denying either doesn't stop a task from being created or saved. The geofence is stored, and the
editor says why it's inactive. Notification permission is asked at the same moment if it hasn't
been asked yet.

`project.yml` carries `NSLocationWhenInUseUsageDescription` and
`NSLocationAlwaysAndWhenInUseUsageDescription`. Region monitoring and significant location changes
need no `location` background mode.

## Picking a place

- **Editor (`TaskDetailView` › Location).** "Remind Me When I Arrive…" opens `PlacePickerView`
  with saved places, current location, and MapKit search (`PlaceSearch`; the query goes to Apple,
  not Neutrino). Picking a spot opens the radius slider (100–2000 m, default 150 m) on a map with
  the circle, plus "Save as a place". Saving needs the account key, and the toggle explains when
  it's missing. Save sends the geofence and the location text in the task's single PATCH.
- **Smart Add `@place`.** The text is matched against decrypted saved-place names: an exact name
  first, then the only name it starts, ignoring case, accents and punctuation (`PlacesService.match`).
  A match is attached on create, and the preview chip shows it. With no match, the task is created
  as before, then the top map result is offered inline ("Remind you when you arrive at Safeway?").
  It's attached only on **Remind Me**. A geofence is never attached on a guess.
- **Settings › Saved Places.** Rename or delete. Deleting clears the place from its tasks on the
  server (`ON DELETE SET NULL`) and locally (`TasksService.forgetPlace`), and stops watching it.

## Nearby

The Tasks filter menu has **Nearby**: within 500 m, 2 km or 10 km. It shows the open tasks with a
place within that distance of the device, measured to the edge of the region, nearest first, with
the distance on each row (`NearbyTasks`). It runs on the device because the server can't read
saved places. It needs only When In Use.

## Not in v1

Alerts on leaving, repeat firing, firing on web/macOS or by server push, and encrypting one-off
points or other task fields.
