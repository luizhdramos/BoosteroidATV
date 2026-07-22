//
//  BoosteroidATVApp.swift
//  BoosteroidATV
//

import BackgroundTasks
import SwiftUI

@main
struct BoosteroidATVApp: App {
    @State private var authManager = AuthManager()

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
            .environment(authManager)
            .onAppear { registerBGTasks() }
            .task { await authManager.initialize() }
        }
    }

    private func registerBGTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.luizhdramos.BoosteroidATV.tokenRefresh",
            using: nil
        ) { task in
            Task { @MainActor in
                authManager.scheduleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }
}
