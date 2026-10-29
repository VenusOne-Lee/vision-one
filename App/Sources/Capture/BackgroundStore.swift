import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VisionOneKit

/// The camera background for the next recording. The bubble previews it
/// live; each take saves the one it was recorded with in background.json,
/// and the editor can change that afterwards.
@MainActor
final class BackgroundStore: ObservableObject {
    static let shared = BackgroundStore()

    @Published var background: CameraBackground {
        didSet {
            guard background != oldValue else { return }
            if let picture = background.picture { lastPicture = picture }
            save()
            needsDepthModel(background)
        }
    }

    /// The last picture chosen, so "Your picture" stays in the menu after
    /// switching to a room and back.
    @Published private(set) var lastPicture: String?

    private static let key = "cameraBackground"
    private static let lastPictureKey = "cameraBackgroundLastPicture"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(CameraBackground.self, from: data) {
            background = saved
        } else {
            background = .off
        }
        lastPicture = defaults.string(forKey: Self.lastPictureKey)
        // A picture deleted from the folder by hand is forgotten.
        if let last = lastPicture,
           !FileManager.default.fileExists(atPath: CameraBackground.picturesFolder.appendingPathComponent(last).path) {
            lastPicture = nil
            if background.style == .picture { background = background.with(style: .off) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(background) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        UserDefaults.standard.set(lastPicture, forKey: Self.lastPictureKey)
    }

    /// "Move with me" on a picture needs the depth model; rooms don't.
    func needsDepthModel(_ background: CameraBackground) {
        if background.style == .picture, background.moveWithMe { DepthModelStore.shared.prepare() }
    }

    /// Asks for a picture and uses it.
    func choosePicture() {
        if let name = Self.importPicture() {
            lastPicture = name
            background = background.with(style: .picture, picture: name)
        }
    }

    /// Opens a picker and copies the chosen picture into the Backgrounds
    /// folder. Returns its new file name, or nil if cancelled or it failed.
    static func importPicture() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a background picture"
        panel.prompt = "Use picture"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let fm = FileManager.default
        let folder = CameraBackground.picturesFolder
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: folder.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }
}

/// The Background menu's items: Off, Blur, the rooms, your picture, then
/// the two switches. Used in the menu bar's Camera row and the editor.
struct BackgroundMenuItems: View {
    @Binding var background: CameraBackground
    var lastPicture: String?
    var choosePicture: () -> Void
    @ObservedObject private var depth = DepthModelStore.shared

    var body: some View {
        choice("Off", selected: background.style == .off) { background = background.with(style: .off) }
        choice("Blur", selected: background.style == .blur) { background = background.with(style: .blur) }
        Divider()
        ForEach(RoomID.allCases, id: \.self) { room in
            choice(room.title, selected: background.style == .room && background.room == room) {
                background = background.with(style: .room, room: room)
            }
        }
        Divider()
        if let picture = background.picture ?? lastPicture {
            choice("Your picture", selected: background.style == .picture) {
                background = background.with(style: .picture, picture: picture)
            }
        }
        Button("Choose picture…", action: choosePicture)
        Divider()
        Toggle("Match my light", isOn: $background.matchLight)
            .disabled(!background.replacesRoom)
        Toggle("Move with me", isOn: $background.moveWithMe)
            .disabled(!background.replacesRoom)
        if background.style == .picture, background.moveWithMe {
            switch depth.state {
            case .downloading: Text("Getting the depth model (50 MB)…")
            case let .failed(message): Text(message)
            case .missing, .ready: EmptyView()
            }
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

/// "Background  Loft ▾" under the Camera switch in the menu bar panel.
struct BackgroundRow: View {
    @ObservedObject private var store = BackgroundStore.shared

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "person.and.background.dotted")
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(Theme.textMuted)
            Text("Background")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: Theme.Space.sm)
            Menu {
                BackgroundMenuItems(background: $store.background, lastPicture: store.lastPicture,
                                    choosePicture: { store.choosePicture() })
            } label: {
                Text(store.background.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("What shows behind you in the camera bubble. You can change it after recording.")
        }
        .frame(minHeight: 26)
    }
}

/// The take's background in the editor. Changing it rewrites
/// background.json; the next export draws the new one.
struct TakeBackgroundMenu: View {
    let take: Take
    @State private var background: CameraBackground = .off

    var body: some View {
        Menu {
            BackgroundMenuItems(background: Binding(get: { background }, set: { save($0) }),
                                lastPicture: BackgroundStore.shared.lastPicture,
                                choosePicture: {
                                    if let name = BackgroundStore.importPicture() {
                                        save(background.with(style: .picture, picture: name))
                                    }
                                })
        } label: {
            Label(background.isOn ? background.title : "Background", systemImage: "person.and.background.dotted")
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What shows behind you in the camera bubble when this take is exported")
        .task(id: take.folder) { background = CameraBackground.read(from: take.backgroundURL) }
    }

    private func save(_ new: CameraBackground) {
        background = new
        try? new.write(to: take.backgroundURL)
        BackgroundStore.shared.needsDepthModel(new)
    }
}
