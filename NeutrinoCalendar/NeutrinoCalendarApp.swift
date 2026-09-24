import SwiftUI
import NeutrinoCore
import NeutrinoAuth
import NeutrinoUI

@main
struct NeutrinoCalendarApp: App {
    // Built in `init()` rather than given a default value here: defaults are evaluated before the
    // initializer body runs, and the shared services resolve their Keychain namespace through
    // `NeutrinoApp.current` the moment they are constructed.
    @StateObject private var authService: AuthService
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var eventsService: EventsService
    @StateObject private var remindersService: RemindersService

    init() {
        // Before anything else. Everything the shared package writes is namespaced `ncal.*`.
        NeutrinoApp.configure(.calendar)
        NeutrinoBrand.use(.calendar)

        let authService = AuthService()
        _authService = StateObject(wrappedValue: authService)
        _networkMonitor = StateObject(wrappedValue: NetworkMonitor())
        let client = CalendarAPIClient(authService: authService)
        _eventsService = StateObject(wrappedValue: EventsService(client: client))
        _remindersService = StateObject(wrappedValue: RemindersService(client: client))
    }

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
                .environmentObject(networkMonitor)
                .environmentObject(eventsService)
                .environmentObject(remindersService)
        }
    }
}

// MARK: - RootContentView

/// Switches between the sign-in screen and the app, and keeps the session alive across launches.
private struct RootContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var eventsService: EventsService
    @EnvironmentObject var remindersService: RemindersService

    var body: some View {
        Group {
            if authService.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }
        }
        .task {
            if authService.isAuthenticated {
                await authService.refreshTokenIfNeeded()
            }
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            if !isAuthenticated {
                eventsService.reset()
                remindersService.reset()
            }
        }
    }
}
