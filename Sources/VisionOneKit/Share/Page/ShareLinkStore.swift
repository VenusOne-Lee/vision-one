import Foundation

extension Take {
    /// The take's share page settings and link, once published.
    public var sharePageURL: URL { folder.appendingPathComponent("share-page.json") }
    /// Notes and watch events pulled from the share page.
    public var viewersURL: URL { folder.appendingPathComponent("viewers.json") }
    /// The last share bundle built for the take.
    public var shareBundleFolder: URL { folder.appendingPathComponent("share-page", isDirectory: true) }
}

/// Where a take's share page lives and how it looks, saved as
/// share-page.json in the take folder.
public struct SharePageRecord: Codable, Equatable, Sendable {
    public enum Host: String, Codable, Sendable {
        /// A static folder the creator puts anywhere. No link until they
        /// tell Vision One where it went.
        case folder
        /// The creator's own Cloudflare account.
        case cloudflare
        /// A Vision One hosted service, if there ever is one.
        case visionOne
    }

    public var slug: String
    public var host: Host
    /// The page's public link, or nil while it's only a folder.
    public var url: URL?
    public var look: SharePageLook
    public var features: SharePageDocument.Features
    public var callToAction: SharePageDocument.CallToAction?
    public var publishedAt: Date?
    /// The exported file the page plays, so Republish knows when the
    /// video changed.
    public var videoFile: String?

    public init(slug: String, host: Host = .folder, url: URL? = nil, look: SharePageLook = SharePageLook(),
                features: SharePageDocument.Features = .init(), callToAction: SharePageDocument.CallToAction? = nil,
                publishedAt: Date? = nil, videoFile: String? = nil) {
        self.slug = slug
        self.host = host
        self.url = url
        self.look = look
        self.features = features
        self.callToAction = callToAction
        self.publishedAt = publishedAt
        self.videoFile = videoFile
    }
}

/// The one place the rest of the app asks "does this take have a share
/// link?". The Post panel shows Copy link and adds the link to posts
/// whenever `link(for:)` isn't nil.
public enum ShareLinkStore {
    public static func record(for take: Take) -> SharePageRecord? {
        guard let data = try? Data(contentsOf: take.sharePageURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharePageRecord.self, from: data)
    }

    /// The take's public share link, or nil when it has none yet.
    public static func link(for take: Take) -> URL? {
        guard let record = record(for: take), record.publishedAt != nil else { return nil }
        return record.url
    }

    public static func save(_ record: SharePageRecord, for take: Take) throws {
        try JSONEncoder.sharePage.encode(record).write(to: take.sharePageURL, options: .atomic)
    }

    /// Forgets the link (the page itself is removed by its host).
    public static func remove(for take: Take, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: take.sharePageURL.path) {
            try fileManager.removeItem(at: take.sharePageURL)
        }
    }
}
