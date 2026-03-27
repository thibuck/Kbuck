// AppDelegate.swift
// Maneja callbacks de APNs (token y errores)

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { String(format: "%02.2hhx", $0) }
        let token = tokenParts.joined()
        print("[APNs] Device Token: \(token)")
        // Aquí puedes enviar el token a tu servidor si usas push remotas
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[APNs] Failed to register: \(error.localizedDescription)")
    }
}
