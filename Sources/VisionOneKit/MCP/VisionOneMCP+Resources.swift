import Foundation

/// A resource as `resources/list` shows it.
public struct MCPResource: Sendable {
    public var uri: String
    public var name: String
    public var title: String
    public var description: String?
    public var mimeType: String

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "uri": .string(uri), "name": .string(name), "title": .string(title), "mimeType": .string(mimeType),
        ]
        if let description { object["description"] = .string(description) }
        return .object(object)
    }
}

/// A family of resources, like every take's transcript.
public struct MCPResourceTemplate: Sendable {
    public var uriTemplate: String
    public var name: String
    public var title: String
    public var description: String
    public var mimeType: String

    public var json: JSONValue {
        [
            "uriTemplate": .string(uriTemplate), "name": .string(name), "title": .string(title),
            "description": .string(description), "mimeType": .string(mimeType),
        ]
    }
}

/// What `resources/read` sends back.
public struct MCPResourceContents: Sendable {
    public var uri: String
    public var mimeType: String
    public var text: String

    public var json: JSONValue {
        ["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)]
    }
}

extension VisionOneMCP {
    static let scheme = "visionone://"

    public static let resourceTemplates: [MCPResourceTemplate] = [
        MCPResourceTemplate(uriTemplate: "visionone://takes/{take}", name: "take", title: "A take",
                            description: "Length, what it's for, cuts, clips and exports. {take} is the folder name.",
                            mimeType: "application/json"),
        MCPResourceTemplate(uriTemplate: "visionone://takes/{take}/transcript", name: "transcript", title: "A take's transcript",
                            description: "The words with times; cuts in ~~ ~~, proposed cuts in [ ].",
                            mimeType: "text/plain"),
    ]

    /// The take list, the task list, and the newest takes.
    public func resources() async -> [MCPResource] {
        var list = [
            MCPResource(uri: "visionone://takes", name: "takes", title: "Takes",
                        description: "Every recording, newest first.", mimeType: "application/json"),
            MCPResource(uri: "visionone://tasks", name: "tasks", title: "Tasks",
                        description: "What Vision One's agents are doing or did.", mimeType: "application/json"),
        ]
        for take in library.takes().prefix(25) {
            let title = take.displayTitle()
            list.append(MCPResource(uri: Self.uri(for: take), name: take.name, title: title,
                                    description: "The take “\(title)”.", mimeType: "application/json"))
            if FileManager.default.fileExists(atPath: take.transcriptURL.path) {
                list.append(MCPResource(uri: Self.uri(for: take) + "/transcript", name: take.name + " transcript",
                                        title: "Transcript of “\(title)”", description: nil, mimeType: "text/plain"))
            }
        }
        return list
    }

    public func read(_ uri: String) async throws -> MCPResourceContents {
        if uri == "visionone://takes" {
            let takes = library.takes().map(listing).map(listingJSON)
            return MCPResourceContents(uri: uri, mimeType: "application/json", text: JSONValue.array(takes).pretty())
        }
        if uri == "visionone://tasks" {
            let jobs = await board.jobs.prefix(50).map(jobJSON)
            return MCPResourceContents(uri: uri, mimeType: "application/json", text: JSONValue.array(jobs).pretty())
        }
        let prefix = Self.scheme + "takes/"
        guard uri.hasPrefix(prefix) else { throw MCPError.notFound("Vision One has no resource \(uri).") }
        var rest = String(uri.dropFirst(prefix.count))
        let wantsTranscript = rest.hasSuffix("/transcript")
        if wantsTranscript { rest = String(rest.dropLast("/transcript".count)) }
        let name = rest.removingPercentEncoding ?? rest
        guard let take = library.takes().first(where: { $0.name == name }) else {
            throw MCPError.notFound("There's no take called \(name).")
        }
        if wantsTranscript {
            guard let transcript = try? Transcript.read(from: take.transcriptURL) else {
                throw MCPError.notFound("“\(take.displayTitle())” has no transcript yet.")
            }
            let edits = (try? EditList.load(from: take.editsURL, sourceDuration: transcript.duration))
                ?? EditList(sourceDuration: transcript.duration)
            let text = Self.transcriptLines(transcript, edits: edits, keptOnly: false).joined(separator: "\n")
            return MCPResourceContents(uri: uri, mimeType: "text/plain", text: text)
        }
        return MCPResourceContents(uri: uri, mimeType: "application/json", text: summary(take).pretty())
    }

    /// visionone://takes/Vision%20One%202026-10-27%20at%2010.53.12
    public static func uri(for take: Take) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return scheme + "takes/" + (take.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? take.name)
    }
}
