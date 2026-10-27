import SwiftUI
import VisionOneKit

/// The iPhone screen picker in the menu bar panel. A plugged-in, unlocked
/// iPhone shows up here; its screen and sound go to phone.mov. (The iPhone
/// as a camera, through Continuity Camera, is listed by `CaptureDevices`
/// for the camera bubble's picker.)
struct SourcesRow: View {
    @ObservedObject var devices: CaptureDevices

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            row("iPhone screen", value: devices.phoneLabel) {
                choice("Off", selected: devices.phoneChoice == .off) { devices.phoneChoice = .off }
                Divider()
                if devices.phones.isEmpty {
                    Text("Plug in an iPhone with USB and unlock it")
                }
                ForEach(devices.phones) { phone in
                    choice(phone.name, selected: devices.phoneChoice == .device(id: phone.id)) {
                        devices.phoneChoice = .device(id: phone.id)
                    }
                }
            }
        }
        .onAppear { devices.refresh() }
    }

    private func row<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Menu {
                content()
            } label: {
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
