//
//  KbuckApp.swift
//  Kbuck
//
//  Created by Augusto Oficina on 10/17/25.
//

import SwiftUI
import UserNotifications

@main
struct KbuckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var storeManager = StoreManager()
    @StateObject private var supabaseService = SupabaseService()

    init() {
        NotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(storeManager)
                .environmentObject(supabaseService)
                .task {
                    await storeManager.requestProducts()
                }
        }
    }
}
