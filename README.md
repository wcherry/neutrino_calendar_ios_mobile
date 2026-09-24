# Neutrino Calendar for iOS

The iOS client for Neutrino Calendar. It is a SwiftUI app on top of the calendar API in
[`wcherry/neutrino`](https://github.com/wcherry/neutrino) (`/api/v1/calendar`) and the shared
`NeutrinoShared` package.

**Status: bootstrap.** Epic 1, the application shell, is in place. The roadmap is
[`agent_docs/road_map.md`](agent_docs/road_map.md).

## Layout

This repository must sit next to `neutrino_shared_ios`, which it consumes by local path:

```
getneutrino.app/
├── neutrino_shared_ios/
└── neutrino_calendar_ios_mobile/   ← this repo
```

## Build

```sh
xcodegen generate          # project.yml is the source of truth
scripts/run_simulator.sh   # build, install and launch on a simulator
xcodebuild test -project NeutrinoCalendar.xcodeproj -scheme NeutrinoCalendar \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Platform registration

- **OAuth client** `neutrino-calendar-ios` is seeded by `neutrino/migrations/00135_oauth__*`.
- **App config and brand** are `NeutrinoAppConfig.calendar` and `NeutrinoBrand.calendar` in
  `neutrino_shared_ios`. The Keychain prefix is `ncal`. Never change or reuse it.
