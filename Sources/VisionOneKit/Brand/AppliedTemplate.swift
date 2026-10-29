import Foundation

/// Defaults are stamped into new takes, never reapplied when reopening one.
public struct ProjectMediaDefaults: Codable, Equatable, Sendable {
    public var templateID: String?
    public var captions: Bool
    public var language: SALanguage?
    public init(templateID: String? = nil, captions: Bool = true, language: SALanguage? = nil) {
        self.templateID = templateID
        self.captions = captions
        self.language = language
    }
}

/// A take owns a snapshot, so changing or deleting a reusable template cannot
/// silently restyle an existing project. User edits remain in their owning files.
public enum AppliedTemplate {
    public static func folder(for take: Take) -> URL {
        take.folder.appendingPathComponent("template", isDirectory: true)
    }
    public static func look(for take: Take) -> TemplateLook? { try? TemplateLook.load(from: folder(for: take)) }
    public static func style(for take: Take) -> CopiedStyle? { CopiedStyle.load(from: folder(for: take)) }
    public static func presets(for take: Take) -> [ExportPreset]? {
        guard let look = look(for: take) else { return nil }
        let values: [ExportPreset] = look.pickedFormats.compactMap {
            switch $0 {
            case .landscape: return .hd1080
            case .vertical: return .vertical
            case .square: return .square
            case .portrait: return nil
            }
        }
        return values.isEmpty ? [.hd1080] : values
    }

    public static func apply(id: String, to take: Take, overwrite: Bool = false,
                             root: URL = UserTemplates.standardFolder) throws {
        if !overwrite, look(for: take) != nil { return }
        let custom = UserTemplates.loadAll(in: root).first { $0.look.id == id }
        guard let look = custom?.look ?? TemplateLook.builtIn(id: id) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let destination = folder(for: take)
        // Validate and snapshot the new manifest before changing take settings.
        try look.save(to: destination)
        let styleURL = destination.appendingPathComponent(CopiedStyle.fileName)
        if let style = custom?.style { try style.save(to: destination) }
        else if FileManager.default.fileExists(atPath: styleURL.path) { try FileManager.default.removeItem(at: styleURL) }
        if let custom {
            for card in [look.intro, look.outro] {
                if let source = TemplateLook.cardURL(card, in: custom.folder),
                   let target = TemplateLook.cardURL(card, in: destination) {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(contentsOf: source).write(to: target, options: .atomic)
                }
            }
        }
        let fm = FileManager.default
        if overwrite || !fm.fileExists(atPath: take.captionSettingsURL.path) {
            var captions = take.loadCaptionSettings()
            captions.isOn = look.captionStyle != nil
            if let style = look.captionStyle { captions.style = style }
            try take.saveCaptionSettings(captions)
        }
        if overwrite || TakePlan.load(for: take) == nil {
            let purpose = Purpose.named(look.purposeID) ?? .demo
            let style = custom?.style
            try TakePlan(purposeID: look.purposeID, energy: style?.energy ?? purpose.energy,
                         targetSeconds: style?.targetSeconds?.upperBound ?? purpose.targetSeconds?.upperBound).write(for: take)
        }
        if overwrite || !fm.fileExists(atPath: take.soundURL.path) {
            var sound = try SoundPlan.load(from: take.soundURL)
            sound.energy = custom?.style?.energy ?? TakePlan.load(for: take)?.energy ?? .calm
            if custom?.style?.wantsMusic == false { sound.music = nil }
            try sound.write(to: take.soundURL)
        }
    }

    public static func stamp(_ defaults: ProjectMediaDefaults?, on take: Take) throws {
        guard let defaults else { return }
        let hadCaptions = FileManager.default.fileExists(atPath: take.captionSettingsURL.path)
        if let id = defaults.templateID { try apply(id: id, to: take) }
        // Existing explicit caption settings win. A template supplies style,
        // while the project's captions and language choices supply availability.
        let marker = take.folder.appendingPathComponent("project-defaults.json")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        if !hadCaptions {
            var settings = take.loadCaptionSettings()
            settings.isOn = defaults.captions
            settings.language = defaults.language
            try take.saveCaptionSettings(settings)
        }
        try JSONEncoder().encode(defaults).write(to: marker, options: .atomic)
    }
}
