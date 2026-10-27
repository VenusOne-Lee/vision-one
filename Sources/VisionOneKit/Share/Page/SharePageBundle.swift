import Foundation

/// Builds the folder a share page is published from:
///
///     index.html    the page, with page.json inlined
///     page.json     the same data, for hosts and the MCP server
///     video.mp4     the exported video
///     poster.jpg    optional
///     captions.vtt  optional
///
/// The folder works anywhere static files do (and opened straight from
/// disk), so it is the same for every host. Only the upload differs.
public enum SharePageBundle {
    static let placeholder = "__VISION_ONE_PAGE_DATA__"

    public enum BundleError: Error, Equatable, LocalizedError {
        case missingTemplate
        case missingVideo(String)

        public var errorDescription: String? {
            switch self {
            case .missingTemplate: return "The share page template is missing from Vision One. Reinstall the app."
            case .missingVideo(let name): return "Export the video first: \(name) isn't there."
            }
        }
    }

    /// share-page.html, shipped inside VisionOneKit.
    public static func template() throws -> String {
        guard let url = Bundle.module.url(forResource: "share-page", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            throw BundleError.missingTemplate
        }
        return html
    }

    /// The template with the page's data inlined. `<` is escaped so no
    /// title or transcript line can close the script tag.
    public static func html(for document: SharePageDocument, template: String) throws -> String {
        let data = try JSONEncoder.sharePage.encode(document)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        return template.replacingOccurrences(of: placeholder, with: json)
    }

    /// Writes the bundle into `folder`, replacing what was there, and
    /// returns index.html's URL.
    @discardableResult
    public static func write(_ document: SharePageDocument, video: URL, poster: URL? = nil,
                             captions: String? = nil, to folder: URL, template: String? = nil,
                             fileManager: FileManager = .default) throws -> URL {
        guard fileManager.fileExists(atPath: video.path) else {
            throw BundleError.missingVideo(video.lastPathComponent)
        }
        var document = document
        document.video = "video.mp4"
        document.poster = poster == nil ? nil : "poster.jpg"
        document.captions = captions == nil ? nil : "captions.vtt"

        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.copyItem(at: video, to: folder.appendingPathComponent("video.mp4"))
        if let poster { try fileManager.copyItem(at: poster, to: folder.appendingPathComponent("poster.jpg")) }
        if let captions {
            try captions.write(to: folder.appendingPathComponent("captions.vtt"), atomically: true, encoding: .utf8)
        }
        try document.write(to: folder.appendingPathComponent("page.json"))
        let index = folder.appendingPathComponent("index.html")
        try html(for: document, template: template ?? Self.template()).write(to: index, atomically: true, encoding: .utf8)
        return index
    }
}
