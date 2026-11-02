import AlarmKit
import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct PillotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared
    @State private var needsOnboarding = AlarmManager.shared.authorizationState == .notDetermined
    @State private var themeChosen = UserDefaults.standard.string(forKey: "theme") != nil
    @State private var languageChosen = AppLanguage.isChosen
    @State private var profileDone = UserDefaults.standard.bool(forKey: "profileDone")

    private static let notificationDelegate = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
        ReminderScheduler.registerCategory()
    }

    var body: some Scene {
        WindowGroup {
            launchScreen
                // Changing the language rebuilds the whole tree so every L(...) is evaluated again.
                .id(model.language)
                .environment(model)
                .environment(\.locale, AppLanguage.locale)
                .fontDesign(.rounded)
                .preferredColorScheme(model.theme.colorScheme)
                .task {
                    // Debug builds only: `-testAlarm YES` schedules the test alarm at launch, for the Simulator.
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "testAlarm") { NSLog("PILLOTDBG test alarm: %@", String(describing: await model.testAlarm())) }
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Opening the app refills the reminders for the next H days.
            if phase == .active { Task { await model.resync() } }
            if phase == .background { AppModel.scheduleRefresh() }
        }
        // iOS decides when, if ever; Diagnostics in Settings shows the last run.
        .backgroundTask(.appRefresh(AppModel.refreshTask)) {
            await AppModel.shared.backgroundRefresh()
        }
    }

    // The `-screen` launch argument only exists for screenshots (theme, language, profile, onboarding, today, meds, history, settings, editor).
    @ViewBuilder
    private var launchScreen: some View {
        switch UserDefaults.standard.string(forKey: "screen") {
        case "language": LanguageView { _ in }
        case "profile": ProfileView {}
        case "onboarding": OnboardingView {}
        case "today": RootView(selectedTab: 0)
        case "editor": MedicationEditor(medication: model.medications.first)
        case "meds": RootView(selectedTab: 1)
        case "history": RootView(selectedTab: 2)
        case "settings": RootView(selectedTab: 3)
        case "theme": ThemeView {}
        default:
            // Installs that already chose a language skip the theme step and keep following the phone.
            if !themeChosen && !languageChosen {
                ThemeView {
                    // Store the choice even when it stays on System, so the step is not shown again.
                    UserDefaults.standard.set(model.theme.rawValue, forKey: "theme")
                    themeChosen = true
                }
            } else if !languageChosen {
                LanguageView { language in
                    model.language = language
                    languageChosen = true
                }
            } else if !profileDone {
                ProfileView {
                    UserDefaults.standard.set(true, forKey: "profileDone")
                    profileDone = true
                }
            } else if needsOnboarding {
                OnboardingView { needsOnboarding = false }
            } else {
                RootView()
            }
        }
    }
}
