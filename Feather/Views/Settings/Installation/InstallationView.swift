import SwiftUI
import NimbleViews

struct InstallationView: View {
    var body: some View {
        NBList(.localized("Installation")) {
            Section {
                Label("التوقيع داخل XSign",systemImage:"signature")
                Text("أضف شهادة P12 وملف MobileProvision مرة واحدة من قسم الشهادات.")
                Label("التثبيت المباشر",systemImage:"arrow.down.app")
                Text("بعد التوقيع اضغط تثبيت، ثم أكّد طلب التثبيت الذي يعرضه iOS.")
            }
            Section {
                Text("يتطلب التثبيت شهادة صالحة لجهازك واتصالاً بالإنترنت.")
                Text("تبقى شهادة التوقيع وكلمة مرورها على جهازك.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .xsignListBackground()
    }
}
