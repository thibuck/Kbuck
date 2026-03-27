// NotificationManager.swift
// Centraliza permisos y programación de notificaciones

import Foundation
import UserNotifications
import UIKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() { super.init() }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("[Notifications] Authorization error: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                if granted {
                    // Intenta registrar para notificaciones push (requiere capability en el proyecto)
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    print("[Notifications] Permission not granted")
                }
            }
        }
    }

    // Programa una notificación local simple para prueba
    func scheduleTestNotification(in seconds: TimeInterval = 5) {
        let content = UNMutableNotificationContent()
        content.title = "Notificación de prueba"
        content.body = "Las notificaciones están activas en Kbuck."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notifications] Scheduling error: \(error.localizedDescription)")
            }
        }
    }

    // Mostrar notificaciones mientras la app está en primer plano
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}
