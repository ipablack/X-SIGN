import SwiftUI
import NimbleViews

struct InstallationView: View {
    var body: some View {
        NBList("التثبيت المحلي") {
            Section {
                Label("التوقيع داخل XSign", systemImage: "signature")
                Text("يستعمل التطبيق شهادة P12 وملف MobileProvision على جهازك. لا يرفع التطبيق أو الشهادة إلى خادم توقيع.")
                Text("يمكن تصدير IPA الموقّع دون إعداد Pairing. التثبيت المباشر يحتاج ملف Pairing خاصاً بالجهاز واتصال النفق المحلي المناسب لإصدار iOS.")
                    .foregroundStyle(.secondary)
            }
            TunnelView()
        }
        .onAppear { UserDefaults.standard.set(1, forKey: "Feather.installationMethod") }
    }
}
