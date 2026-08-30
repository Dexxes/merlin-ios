import SwiftUI
import Observation
import UserNotifications

// MARK: – Navigation router

/// Shared observable object that carries deep-link navigation requests from the
/// notification delegate (or other sources) to the view hierarchy.
@MainActor
@Observable
final class AppNavigator {
    static let shared = AppNavigator()
    private init() {}

    /// Set by AppDelegate when the user taps a reminder notification.
    /// ArticleListView observes this and opens the matching article.
    var articleIdToOpen: Int? = nil
}

// MARK: – App delegate

/// Handles UNUserNotificationCenter callbacks (notification tap, foreground presentation).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // User tapped a notification — navigate to the article.
    // nonisolated satisfies the protocol's non-actor requirement; we hop to
    // @MainActor explicitly for the AppNavigator mutation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let articleId = response.notification.request.content.userInfo["articleId"] as? Int {
            Task { @MainActor in
                AppNavigator.shared.articleIdToOpen = articleId
            }
        }
        let notificationId = response.notification.request.identifier
        Task {
            await ReminderService.shared.markFired(notificationId: notificationId)
        }
        completionHandler()
    }

    // Show notification as banner when the app is already in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: – Splash screen

private struct SplashView: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 24) {
                if let url = Bundle.module.url(forResource: "merlin-logo", withExtension: "png"),
                   let uiImage = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                }
                ProgressView()
                    .tint(.gray)
            }
        }
    }
}

// MARK: – App

@main
struct MerlinApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var splashVisible = true

    /// Reacts to theme changes so the whole app (cards, flyout, sheets)
    /// switches colour scheme immediately — not just the reader.
    @AppStorage("merlin_reader_theme") private var readerThemeRaw: String = "auto"

    private let sharedViewModel = ArticlesViewModel()

    init() {
        // Migrate existing credentials from standard UserDefaults into the shared
        // App Group container so the Share Extension can access them.
        CredentialsStore.shared.migrateToGroupDefaultsIfNeeded()
    }

    /// Maps the reader theme to a SwiftUI colour scheme override.
    /// `.auto` and `.sepia` return `nil` so the system setting is respected.
    private var preferredScheme: ColorScheme? {
        switch ReaderTheme(rawValue: readerThemeRaw) ?? .auto {
        case .dark:         return .dark
        case .light:        return .light
        case .auto, .sepia: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ArticleListView()
                    .environment(sharedViewModel)
                    .environment(AppNavigator.shared)

                if splashVisible {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(preferredScheme)
            .animation(.easeOut(duration: 0.3), value: splashVisible)
            .task {
                // Server-Settings einmal pro App-Start ziehen ("Server gewinnt"),
                // statt erst beim Öffnen von SettingsView – sonst zeigt z.B. der
                // Reader/Fortschrittsbalken bis zum ersten Settings-Besuch noch die
                // alte/lokale Akzentfarbe statt der zuletzt vom Server gesetzten.
                if CredentialsStore.shared.isConfigured,
                   let serverSettings = try? await MerlinAPI.shared.getSettings() {
                    PreferencesStore.shared.loadFromServer(serverSettings)

                    // `sharedViewModel.selectedFilter` wurde oben beim App-Start synchron aus dem
                    // lokalen Cache initialisiert (siehe `ArticlesViewModel.selectedFilter`-Property),
                    // BEVOR dieser Block läuft – und `ArticleListView` lädt parallel dazu in ihrem
                    // eigenen `.task` bereits mit diesem (ggf. veralteten) Filter. Ohne diese Zeile
                    // bleibt die Liste auf dem alten lokalen Default stehen, selbst nachdem der
                    // Server-Wert gerade eben korrekt in UserDefaults geschrieben wurde – es gibt
                    // sonst keine reaktive Verbindung zwischen PreferencesStore und dem ViewModel.
                    // `ArticleListView` reagiert per `.onChange(of: viewModel.selectedFilter)` und
                    // lädt dann automatisch mit dem korrekten Filter neu.
                    sharedViewModel.selectedFilter = PreferencesStore.shared.defaultFilter
                }

                // Server-Capabilities abfragen, damit optionale UI (aktuell:
                // der Vorlesen-Button) ausgeblendet bleibt, wenn der Server
                // keinen erreichbaren TTS-Daemon hat, statt es erst beim
                // ersten Tippen per Fehlermeldung zu entdecken.
                if CredentialsStore.shared.isConfigured,
                   let capabilities = try? await MerlinAPI.shared.getCapabilities() {
                    PreferencesStore.shared.ttsAvailable = capabilities.tts.available
                }

                // Show splash at least briefly, then wait for first load to finish.
                try? await Task.sleep(nanoseconds: 200_000_000)
                while sharedViewModel.isLoading && sharedViewModel.articles.isEmpty {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                splashVisible = false
            }
        }
    }
}
