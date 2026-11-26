import SwiftUI
import UserNotifications

@MainActor
final class XSignImportNotices: ObservableObject {
    static let shared = XSignImportNotices()
    nonisolated static let preference = "xsign.notice.importComplete"
    nonisolated static let category = "xsign.importComplete"
    @Published var openLibrary = false

    static func registerCategory() {
        let center = UNUserNotificationCenter.current()
        let action = UNNotificationAction(identifier: "xsign.openImportedLibrary",
            title: xsignText("فتح مكتبة التوقيع"), options: .foreground)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [action], intentIdentifiers: []),
            UNNotificationCategory(identifier: XSignPushNotifications.category, actions: [], intentIdentifiers: [])
        ])
    }

    static func completed() {
        guard UserDefaults.standard.bool(forKey: preference) else { return }
        let content = UNMutableNotificationContent()
        content.title = xsignText("تم الاستيراد")
        content.body = xsignText("افتح مكتبة التوقيع لمراجعة التطبيق المستورد.")
        content.categoryIdentifier = category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
            content: content, trigger: nil), withCompletionHandler: nil)
    }
}

struct XSignImportNoticeToggle: View {
    @AppStorage(XSignImportNotices.preference) private var enabled = false
    @State private var asking = false
    @State private var denied = false

    var body: some View {
        Toggle(isOn: Binding(get: { enabled }, set: update)) {
            Label(xsignText("إشعار اكتمال الاستيراد"), systemImage: "bell")
        }
        .disabled(asking)
        .alert(xsignText("فعّل إشعارات XSign من إعدادات الجهاز."), isPresented: $denied) {
            Button(xsignText("حسناً"), role: .cancel) {}
        }
    }

    private func update(_ value: Bool) {
        guard value else { enabled = false; return }
        asking = true
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])) == true
            enabled = granted
            denied = !granted
            asking = false
        }
    }
}
