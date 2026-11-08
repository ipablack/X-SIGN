import SwiftUI

struct InstallationView: View {
    @AppStorage(XSignOTAInstallMode.storageKey) private var savedMode = XSignOTAInstallMode.palera.rawValue

    private var mode: Binding<XSignOTAInstallMode> {
        Binding(
            get: { XSignOTAInstallMode.resolve(savedMode) },
            set: { savedMode = $0.rawValue }
        )
    }

    var body: some View {
        Menu {
            Section {
                Picker("طريقة التثبيت", selection: mode) {
                    ForEach(XSignOTAInstallMode.allCases, id: \.rawValue) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("الطريقة الافتراضية تستخدم خدمة Feather لملف وصف التثبيت. ملف IPA يبقى على الآيفون.")
            }
        } label: {
            HStack {
                Label("التثبيت", systemImage: "arrow.down.circle")
                    .foregroundStyle(.primary)
                Spacer()
                Text(mode.wrappedValue.title).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }
}
