import Foundation

/// The places the export sheet shares a finished video to. Each one picks
/// the exported file that suits it, the words that go with it (the
/// Sharer's draft, when there is one) and the page or app that opens.
/// Web composers can't take a video by link, so the file is shown in
/// Finder to drag in and the words go on the clipboard as well.
public enum ShareTarget: String, CaseIterable, Sendable, Identifiable {
    case whatsapp
    case linkedin
    case x
    case youtube

    public var id: String { rawValue }

    /// The target a Sharer post is for: "x", "twitter", "linkedin",
    /// "whatsapp", "youtube".
    public init?(network: String) {
        switch network.lowercased() {
        case "x", "twitter": self = .x
        case "linkedin": self = .linkedin
        case "whatsapp": self = .whatsapp
        case "youtube": self = .youtube
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .whatsapp: return "WhatsApp"
        case .linkedin: return "LinkedIn"
        case .x: return "X"
        case .youtube: return "YouTube"
        }
    }

    /// The SharePack post network this target uses.
    public var network: String { rawValue }

    /// Where the post goes, for the approval record.
    public var destination: String {
        switch self {
        case .whatsapp: return "wa.me"
        case .linkedin: return "linkedin.com"
        case .x: return "x.com"
        case .youtube: return "youtube.com"
        }
    }

    /// Exports that suit this target, best first.
    public var preferred: [ExportPreset] {
        switch self {
        // Small enough to send on mobile data, then the phone's own shape.
        case .whatsapp: return [.whatsapp, .vertical, .hd720, .square, .hd1080, .original]
        // Square takes the most room in the feed.
        case .linkedin: return [.square, .hd1080, .vertical, .hd720, .original, .whatsapp]
        case .x: return [.hd1080, .square, .hd720, .vertical, .original, .whatsapp]
        // A vertical upload becomes a Short.
        case .youtube: return [.hd1080, .original, .hd720, .vertical, .square, .whatsapp]
        }
    }

    /// The file to share from what was exported: the best suited one, or
    /// nil when nothing was.
    public func file(from exported: [ExportPreset: URL]) -> (preset: ExportPreset, url: URL)? {
        for preset in preferred {
            if let url = exported[preset] { return (preset, url) }
        }
        return nil
    }

    /// The words to go with the video: the Sharer's post for this network,
    /// or for YouTube the title, description and chapters. Nil without a
    /// draft.
    public func text(in pack: SharePack?) -> String? {
        guard let pack else { return nil }
        if self == .youtube {
            let parts = [pack.title, pack.description, pack.chapterText].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        let post = pack.posts.first { ShareTarget(network: $0.network) == self }
        guard let text = post?.text, !text.isEmpty else { return nil }
        return text
    }

    /// The composer to open, with `text` filled in where the network
    /// takes it in the link.
    public func composer(text: String?) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = (text ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let url: String
        switch self {
        case .whatsapp:
            url = encoded.isEmpty ? "https://wa.me/" : "https://wa.me/?text=\(encoded)"
        case .linkedin:
            url = encoded.isEmpty ? "https://www.linkedin.com/feed/?shareActive=true"
                : "https://www.linkedin.com/feed/?shareActive=true&text=\(encoded)"
        case .x:
            url = encoded.isEmpty ? "https://x.com/compose/post" : "https://x.com/intent/post?text=\(encoded)"
        case .youtube:
            // YouTube has no text in the link; the words go on the clipboard.
            url = "https://www.youtube.com/upload"
        }
        return URL(string: url)!
    }

    /// What happens when the post is approved, in plain words for the
    /// approval card.
    public func steps(file: ExportPreset?) -> [String] {
        var steps: [String] = []
        if let file {
            steps.append("Shows the \(file.title) video in Finder, ready to drag into the post")
        }
        switch self {
        case .youtube:
            steps.append("Copies the title, description and chapters")
            steps.append("Opens YouTube's upload page. Nothing goes up until you publish there.")
        case .whatsapp:
            steps.append("Copies the text and opens WhatsApp. Nothing sends until you press Send there.")
        case .linkedin, .x:
            steps.append("Copies the text and opens \(destination). Nothing posts until you press Post there.")
        }
        return steps
    }
}
