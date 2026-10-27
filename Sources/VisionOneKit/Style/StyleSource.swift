import Foundation

/// Sites whose videos Vision One never downloads. Their terms only allow
/// watching, so a link from one of these plays in a Vision One window and
/// is read as it plays. See docs/STYLE.md.
public enum StylePlatform: String, CaseIterable, Codable, Sendable {
    case youtube, tiktok, instagram, x, linkedin, vimeo, facebook

    public var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .x: return "X"
        case .linkedin: return "LinkedIn"
        case .vimeo: return "Vimeo"
        case .facebook: return "Facebook"
        }
    }

    /// Hosts, matched exactly or as a parent domain ("m.youtube.com").
    var hosts: [String] {
        switch self {
        case .youtube: return ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        case .tiktok: return ["tiktok.com"]
        case .instagram: return ["instagram.com"]
        case .x: return ["x.com", "twitter.com"]
        case .linkedin: return ["linkedin.com"]
        case .vimeo: return ["vimeo.com"]
        case .facebook: return ["facebook.com", "fb.watch"]
        }
    }

    public static func matching(host: String) -> StylePlatform? {
        let host = host.lowercased()
        return allCases.first { platform in
            platform.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

/// What the person dropped or pasted into Copy a style.
public enum StyleSource: Equatable, Sendable {
    /// A video file on the Mac.
    case file(URL)
    /// A direct link to a video file (.mp4, .mov, .m4v), read like a file
    /// but never saved.
    case videoLink(URL)
    /// A link on a video site: played in a Vision One window, not downloaded.
    case platform(StylePlatform, URL)
    /// Any other web page with a video on it, played the same way.
    case webPage(URL)

    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Reads pasted text or a dropped URL. Nil when it isn't something
    /// Vision One can open (empty, not a web link, a file that isn't a video).
    public static func classify(_ text: String) -> StyleSource? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("<", ">"), ("\"", "\""), ("'", "'")] where value.hasPrefix(open) && value.hasSuffix(close) && value.count > 1 {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty, !value.contains(" ") || value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("file:") else {
            return nil
        }
        if value.hasPrefix("/") || value.hasPrefix("~") {
            return classify(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
        }
        if !value.contains("://"), value.contains("."), let first = value.first, first.isLetter || first.isNumber {
            value = "https://" + value
        }
        guard let url = URL(string: value) else { return nil }
        return classify(url)
    }

    public static func classify(_ url: URL) -> StyleSource? {
        if url.isFileURL {
            return videoExtensions.contains(url.pathExtension.lowercased()) ? .file(url) : nil
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".") else { return nil }
        if let platform = StylePlatform.matching(host: host) {
            return .platform(platform, url)
        }
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            return .videoLink(url)
        }
        return .webPage(url)
    }

    /// File and direct video links are read straight from the bytes; the
    /// rest has to play in a window.
    public var readsDirectly: Bool {
        switch self {
        case .file, .videoLink: return true
        case .platform, .webPage: return false
        }
    }

    public var url: URL {
        switch self {
        case let .file(url), let .videoLink(url), let .platform(_, url), let .webPage(url): return url
        }
    }

    /// Where it came from, for the template card: a file name or a host.
    /// Never the full link, which can carry tracking ids.
    public var label: String {
        switch self {
        case let .file(url): return url.lastPathComponent
        case let .videoLink(url): return (url.host ?? "") + "/" + url.lastPathComponent
        case let .platform(platform, _): return platform.title
        case let .webPage(url): return url.host ?? url.absoluteString
        }
    }

    /// One line under the paste field.
    public var explanation: String {
        switch self {
        case .file: return "A video on this Mac. It is read here and left as it is."
        case .videoLink: return "A direct video link. It is read from the link and not saved."
        case let .platform(platform, _):
            return "\(platform.title) link. It plays in a Vision One window while it is read. Nothing is downloaded."
        case .webPage: return "A web page. It plays in a Vision One window while it is read. Nothing is downloaded."
        }
    }
}
