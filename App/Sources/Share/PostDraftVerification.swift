import AppKit
import SwiftUI
import VisionOneKit

/// Mount the same production PostPanel and switch its take, retaining the
/// hosting view. No approval, clipboard, browser or outbound action is invoked.
@MainActor
enum PostDraftVerification {
    private final class Fixture: ObservableObject {
        @Published var take: Take
        var owners: [String: PostDraftControl] = [:]
        init(_ take: Take) { self.take = take }
    }
    private struct Surface: View {
        @ObservedObject var fixture: Fixture
        var body: some View {
            PostPanel(take: fixture.take) { target, owner in
                fixture.owners[target.network] = owner
            }
        }
    }
    private static func mounted(_ fixture: Fixture, take: Take) async throws -> PostDraftControl {
        for _ in 0..<200 {
            if let owner = fixture.owners["linkedin"], owner.take.folder == take.folder { return owner }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MediaVerification.Failure(message: "Post panel did not mount current take owner")
    }

    static func run(in root: URL) async throws {
        let parent = root.appendingPathComponent("post-draft-regression")
        if FileManager.default.fileExists(atPath: parent.path) { try FileManager.default.removeItem(at: parent) }
        let a = Take(folder: parent.appendingPathComponent("A"))
        let b = Take(folder: parent.appendingPathComponent("B"))
        for take in [a, b] { try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true) }
        let fixture = Fixture(a)
        let host = NSHostingView(rootView: Surface(fixture: fixture).themed())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let first = try await mounted(fixture, take: a)
        first.edit("A manual LinkedIn")
        first.open = true
        first.asking = true
        first.posted = true
        let aBytes = try Data(contentsOf: PostDrafts.url(for: a))
        fixture.take = b
        let second = try await mounted(fixture, take: b)
        try MediaVerification.require(second !== first && second.manualText == nil && !second.asking && !second.posted && !second.open,
                                      "Post copy or approval state leaked from A to B")
        second.edit("B manual LinkedIn")
        try MediaVerification.require(try Data(contentsOf: PostDrafts.url(for: a)) == aBytes, "Editing B changed A's post copy")
        fixture.take = a
        // Wait for a newly mounted owner, not the old fixture dictionary entry.
        fixture.owners.removeAll()
        let returned = try await mounted(fixture, take: a)
        try MediaVerification.require(returned !== first && returned.manualText == "A manual LinkedIn" && !returned.asking && !returned.posted,
                                      "Returning to A lost manual copy or retained approval")
        let relaunched = PostDraftControl(take: b, destination: "linkedin")
        try MediaVerification.require(relaunched.manualText == "B manual LinkedIn" && !relaunched.asking && !relaunched.posted,
                                      "Recreated post owner lost B's saved draft")
        relaunched.edit("")
        try MediaVerification.require(PostDraftControl(take: b, destination: "linkedin").manualText == "",
                                      "Explicitly cleared copy fell back to generated text")
        let invalid = Data("invalid saved draft".utf8)
        try invalid.write(to: PostDrafts.url(for: b))
        let broken = PostDraftControl(take: b, destination: "x")
        broken.edit("must not replace unreadable copy")
        try MediaVerification.require(!broken.loaded && broken.problem != nil && (try Data(contentsOf: PostDrafts.url(for: b))) == invalid,
                                      "Unreadable manual drafts were silently overwritten")
        let c = Take(folder: parent.appendingPathComponent("write-retry"))
        try FileManager.default.createDirectory(at: c.folder, withIntermediateDirectories: true)
        let retry = PostDraftControl(take: c, destination: "linkedin")
        try FileManager.default.createDirectory(at: PostDrafts.url(for: c), withIntermediateDirectories: false)
        retry.edit("Retain unsaved copy")
        try MediaVerification.require(retry.loaded && retry.manualText == "Retain unsaved copy" && retry.problem != nil,
                                      "Post save failure lost the visible draft or retry")
        try FileManager.default.removeItem(at: PostDrafts.url(for: c))
        retry.save()
        try MediaVerification.require(retry.problem == nil && PostDraftControl(take: c, destination: "linkedin").manualText == "Retain unsaved copy",
                                      "Retry did not persist the retained post copy")
        try MediaVerification.require(!PostCopy.canDraft(for: a) && !PostCopy.canDraft(for: b), "Silent post-copy entry incorrectly enabled")
        try JSONSerialization.data(withJSONObject: ["mountedTakeSwitch": true, "manualDraftsPersist": true,
            "approvalStateReset": true, "otherTakeBytesUnchanged": true, "explicitEmptyPreserved": true,
            "unreadableDraftPreserved": true, "saveFailureRetryRetainsCopy": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("post-drafts.json"))
        print("Native mounted post take-switch, saved copy and approval-state isolation verification passed")
    }
}
