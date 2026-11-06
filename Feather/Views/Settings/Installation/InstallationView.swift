import SwiftUI
import NimbleViews

struct InstallationView: View {
    var body: some View {
        NBList("التثبيت بطريقة Feather") {
            Section {
                Label("التوقيع داخل XSign",systemImage:"signature")
                Text("تستخدم شهادة P12 وMobileProvision المحفوظة على جهازك.")
                Label("Feather Semi Local",systemImage:"arrow.down.app")
                Text("تُنشئ خدمة api.palera.in ملف التثبيت عبر HTTPS. ينقل iOS ملف التطبيق من خادم مؤقت على جهازك فقط.")
            }
            Section {
                Text("لا يحتاج المسار إلى Pairing أو VPN أو نشر خدمة في Firebase. تبقى الشهادة الصالحة والاتصال وتأكيد iOS مطلوبة.")
                Text("الخدمة تستقبل البندل والإصدار وعنوان التثبيت المحلي المؤقت. لا تُرفع شهادة التوقيع أو كلمة مرورها أو بايتات IPA إليها.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
