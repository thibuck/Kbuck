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
    private let splashDurationNanoseconds: UInt64 = 4_500_000_000

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hpdCachedEntries") private var hpdCachedEntriesData: Data = Data()
    @StateObject private var storeManager = StoreManager()
    @StateObject private var supabaseService = SupabaseService()
    @State private var showsLaunchSplash = true

    init() {
        NotificationManager.shared.configure()
    }

    private var splashTotalCount: Int? {
        guard
            let entries = try? JSONDecoder().decode([HPDEntry].self, from: hpdCachedEntriesData),
            !entries.isEmpty
        else {
            return nil
        }

        return entries.reduce(into: 0) { count, entry in
            if !isDateInPast(entry.dateScheduled) {
                count += 1
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(storeManager)
                    .environmentObject(supabaseService)
                    .task {
                        await storeManager.requestProducts()
                    }

                if showsLaunchSplash {
                    AuctionSplashView(totalCount: splashTotalCount)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                guard showsLaunchSplash else { return }
                try? await Task.sleep(nanoseconds: splashDurationNanoseconds)
                withAnimation(.easeOut(duration: 0.35)) {
                    showsLaunchSplash = false
                }
            }
        }
    }
}
