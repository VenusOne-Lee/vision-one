import AppKit
import UniformTypeIdentifiers
import VisionOneKit

/// The builder's brand kit, loaded once and saved on every change.
/// Export reads it for the intro, outro, corner logo and caption ring.
@MainActor
final class BrandStore: ObservableObject {
    static let shared = BrandStore()

    let folder: URL

    @Published var kit: BrandKit {
        didSet { if kit != oldValue { save() } }
    }
    @Published private(set) var problem: String?
    @Published private(set) var logoImage: NSImage?

    init(folder: URL = BrandKit.standardFolder) {
        self.folder = folder
        do {
            kit = try BrandKit.load(from: folder)
        } catch {
            kit = BrandKit()
            problem = "brand.json couldn't be read, so this is the default brand. Changing anything here replaces it."
        }
        logoImage = kit.logoURL(in: folder).flatMap(NSImage.init(contentsOf:))
    }

    private func save() {
        do {
            try kit.save(to: folder)
            problem = nil
        } catch {
            problem = "Couldn't save your brand. \(error.localizedDescription)"
        }
    }

    // MARK: - Logo

    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.title = "Choose your logo"
        panel.allowedContentTypes = [.png, .jpeg, .svg, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var updated = kit
            try updated.importLogo(from: url, into: folder)
            logoImage = updated.logoURL(in: folder).flatMap(NSImage.init(contentsOf:))
            kit = updated
        } catch {
            problem = "Couldn't use that logo. \(error.localizedDescription)"
        }
    }

    func removeLogo() {
        if let url = kit.logoURL(in: folder) {
            try? FileManager.default.removeItem(at: url)
        }
        logoImage = nil
        kit.logo = nil
    }

    // MARK: - Export

    /// Intro and outro for an export. The plan inside decides whether
    /// any card is drawn, so this is safe to pass every time.
    func cardMaker(look: TemplateLook? = nil, templateFolder: URL? = nil) -> CardMaker {
        CardMaker(brand: kit, brandFolder: folder, look: look, templateFolder: templateFolder)
    }

    /// The corner logo, when it's on, there is a logo, and the template
    /// allows it.
    func overlays(look: TemplateLook? = nil) -> [ExportOverlay] {
        guard kit.watermark.enabled, look?.watermark != false,
              let data = kit.logoURL(in: folder).flatMap({ try? Data(contentsOf: $0) }),
              let logo = CardMaker.decode(data) else { return [] }
        return [WatermarkOverlay(logo: logo, watermark: kit.watermark)]
    }

    /// What template cards are filled with.
    var cardVariables: CardVariables {
        let url = kit.logoURL(in: folder)
        return CardVariables(brand: kit, logo: url.flatMap { try? Data(contentsOf: $0) },
                             logoType: CardVariables.mimeType(forExtension: url?.pathExtension ?? "png"))
    }
}
