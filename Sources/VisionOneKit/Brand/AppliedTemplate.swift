import Foundation

/// Defaults are stamped into new takes, never reapplied when reopening one.
public struct ProjectMediaDefaults: Codable, Equatable, Sendable {
    public var templateID: String?
    public var captions: Bool
    public var language: SALanguage?
    public var captureChoice: CaptureChoice?
    public var countdownSeconds: Int?
    public init(templateID: String? = nil, captions: Bool = true, language: SALanguage? = nil) {
        self.templateID = templateID
        self.captions = captions
        self.language = language
        self.captureChoice = nil
        self.countdownSeconds = nil
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
    /// Explicit brand paper/ink overrides win over copied palette suggestions.
    public static func cardBrand(for take: Take, base: BrandKit) -> BrandKit {
        guard let style = style(for: take), style.copies(.colours),
              base.paperHex == BrandKit().paperHex, base.inkHex == BrandKit().inkHex else { return base }
        let colours = style.profile.palette.compactMap { swatch -> (hex: UInt32, luminance: Double)? in
            guard let hex = UInt32(swatch.hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
            return (hex, StyleRGB(hex: hex).luminance)
        }.sorted { $0.luminance < $1.luminance }
        guard let dark = colours.first, let light = colours.last,
              light.luminance - dark.luminance > 0.45 else { return base }
        let ink = dark.hex
        let paper = light.hex
        var result = base
        result.inkHex = ink
        result.paperHex = paper
        return result
    }

    public static func presets(for take: Take) -> [ExportPreset]? {
        guard let look = look(for: take) else { return nil }
        let values: [ExportPreset] = look.pickedFormats.compactMap {
            switch $0 {
            case .landscape: return .hd1080
            case .vertical: return .vertical
            case .square: return .square
            case .portrait: return .portrait
            }
        }
        return values.isEmpty ? [.hd1080] : values
    }

    public static func apply(id: String, to take: Take, overwrite: Bool = false,
                             root: URL = UserTemplates.standardFolder) throws {
        try transact(take) {
            try applyUnchecked(id: id, to: take, overwrite: overwrite, root: root)
        }
    }

    private static func applyUnchecked(id: String, to take: Take, overwrite: Bool, root: URL) throws {
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
        let marker = take.folder.appendingPathComponent("project-defaults.json")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try transact(take) {
            let hadCaptions = FileManager.default.fileExists(atPath: take.captionSettingsURL.path)
            if let id = defaults.templateID { try apply(id: id, to: take) }
            // Existing explicit caption settings win. A template supplies style,
            // while the project's captions and language choices supply availability.
            if !hadCaptions {
                var settings = take.loadCaptionSettings()
                settings.isOn = defaults.captions
                settings.language = defaults.language
                try take.saveCaptionSettings(settings)
            }
            try JSONEncoder().encode(defaults).write(to: marker, options: .atomic)
        }
    }

    private struct RollbackFailure: LocalizedError {
        let original: Error
        let recovery: URL
        var errorDescription: String? {
            "Template application failed (\(original.localizedDescription)) and could not be fully restored. The previous settings are preserved at \(recovery.path)."
        }
    }

    /// Backs up only the sidecars this operation owns. Media and other edits
    /// never move. On any failure restore the previous template and settings.
    private static func transact(_ take: Take, _ change: () throws -> Void) throws {
        let fm = FileManager.default
        let backup = take.folder.appendingPathComponent(".template-rollback-\(UUID().uuidString)", isDirectory: true)
        let names = ["template", "captions.json", "plan.json", "sound.json", "project-defaults.json"]
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var canDiscardBackup = true
        defer { if canDiscardBackup { try? fm.removeItem(at: backup) } }
        for name in names {
            let source = take.folder.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: backup.appendingPathComponent(name)) }
        }
        do { try change() }
        catch {
            let original = error
            do {
                for name in names {
                    let target = take.folder.appendingPathComponent(name)
                    let saved = backup.appendingPathComponent(name)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    if fm.fileExists(atPath: saved.path) { try fm.copyItem(at: saved, to: target) }
                }
            } catch {
                canDiscardBackup = false
                throw RollbackFailure(original: original, recovery: backup)
            }
            throw original
        }
    }
}
