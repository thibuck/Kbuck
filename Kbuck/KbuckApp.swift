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
    @AppStorage("sheriffCachedEntries") private var sheriffCachedEntriesData: Data = Data()
    @StateObject private var storeManager = StoreManager()
    @StateObject private var supabaseService = SupabaseService()
    @State private var showsLaunchSplash = true

    init() {
        NotificationManager.shared.configure()
    }

    private var splashHPDCount: Int? {
        let entries = decodeAuctionEntries(hpdCachedEntriesData)
        guard !entries.isEmpty else { return nil }
        return entries.reduce(into: 0) { count, entry in
            if !isDateInPast(entry.dateScheduled) { count += 1 }
        }
    }

    private var splashSheriffCount: Int? {
        let entries = decodeAuctionEntries(sheriffCachedEntriesData)
        guard !entries.isEmpty else { return nil }
        return entries.reduce(into: 0) { count, entry in
            if !isDateInPast(entry.dateScheduled) { count += 1 }
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
                    AuctionSplashView(hpdCount: splashHPDCount, sheriffCount: splashSheriffCount)
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
