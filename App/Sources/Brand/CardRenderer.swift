import AppKit
import ImageIO
import UniformTypeIdentifiers
import VisionOneKit
import WebKit

/// Renders a HyperFrames-style HTML card into frames, without Chrome.
/// HyperFrames seeks a headless browser to each frame time and captures
/// it; this does the same with WebKit: load the card off screen, fill in
/// the brand, then for each frame pause every animation at that time and
/// take a snapshot. Only short cards go through here; the recording
/// itself stays on the AVFoundation path.
@MainActor
final class CardRenderer: NSObject, WKNavigationDelegate {
    enum Failure: LocalizedError {
        case load(Error?)
        case snapshot(Error?)
        case blank
        case timedOut
        case networkRules(Error?)

        var errorDescription: String? {
            switch self {
            case let .load(error): return "Couldn't open the card. \(error?.localizedDescription ?? "")"
            case let .snapshot(error): return "Couldn't draw the card. \(error?.localizedDescription ?? "")"
            case let .networkRules(error): return "Couldn’t enforce offline card rendering. \(error?.localizedDescription ?? "")"
            case .blank: return "The card came out blank."
            case .timedOut: return "The card took too long to draw."
            }
        }
    }

    private var navigation: CheckedContinuation<Void, Error>?
    private static var rules: WKContentRuleList?

    /// Renders `duration` seconds of the card at `size` pixels.
    /// `readAccess` is the folder the card may load files from (its
    /// template folder); nothing on the network loads.
    func render(card url: URL, readAccess: URL, variables: CardVariables,
                size: CGSize, frameRate: Int, duration: Double) async throws -> RenderedCard {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.add(try await Self.offlineRules())

        let frame = CGRect(origin: .zero, size: size)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self

        // WebKit only paints inside a window. This one is borderless, sits
        // behind everything far off screen, and is left out of recordings.
        let window = NSWindow(contentRect: frame.offsetBy(dx: -30_000, dy: -30_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderBack(nil)
        defer {
            webView.navigationDelegate = nil
            window.orderOut(nil)
            window.contentView = nil
        }

        try await load(url, readAccess: readAccess, in: webView)
        _ = try await webView.callAsyncJavaScript(CardScript.prepare, arguments: [
            "text": variables.text,
            "css": variables.css,
            "logo": variables.logoDataURL ?? NSNull(),
        ], contentWorld: .page)

        var frames: [Data] = []
        var order: [Int] = []
        var lastPixels: Data?
        var paint = CardPaintEvidence()
        let times = CardScript.frameTimes(duration: duration, frameRate: frameRate)
        for t in times {
            try Task.checkCancellation()
            _ = try await webView.callAsyncJavaScript(CardScript.seek, arguments: ["t": t], contentWorld: .page)
            let image = try await snapshot(webView, size: size)
            guard let encoded = Self.encode(image, size: size) else { throw Failure.snapshot(nil) }
            let (png, pixels) = encoded
            paint.observe(pixels)
            if let lastPixels, lastPixels == pixels, !frames.isEmpty {
                order.append(frames.count - 1)
            } else {
                frames.append(png)
                order.append(frames.count - 1)
            }
            lastPixels = pixels
        }
        // A web view that never painted gives one flat colour throughout.
        guard paint.hasPaint else { throw Failure.blank }
        return RenderedCard(frameRate: frameRate, frames: frames, order: order)
    }

    // MARK: - Loading

    private func load(_ url: URL, readAccess: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated { self?.finishNavigation(.failure(Failure.timedOut)) }
            }
        }
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        guard let navigation else { return }
        self.navigation = nil
        navigation.resume(with: result)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishNavigation(.success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation(.failure(Failure.load(error))) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation(.failure(Failure.load(error))) }
    }

    /// Blocks http(s) and sockets, so a card can't fetch anything and
    /// renders the same every time.
    static func offlineRules() async throws -> WKContentRuleList {
        if let rules { return rules }
        let compiled = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "VisionOneCardsOfflineV2",
                encodedContentRuleList: CardScript.blockNetworkRules
            ) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: Failure.networkRules(error)) }
            }
        }
        rules = compiled
        return compiled
    }

    // MARK: - Frames

    private func snapshot(_ webView: WKWebView, size: CGSize) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: Failure.snapshot(error))
                }
            }
        }
    }

    /// Draws the snapshot at exactly `size` pixels (snapshots come at the
    /// screen's scale) and returns it as PNG plus its raw pixels, used to
    /// spot repeated frames.
    private static func encode(_ image: NSImage, size: CGSize) -> (Data, Data)? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let drawn = context.makeImage(), let raw = context.data else { return nil }
        let pixels = Data(bytes: raw, count: context.bytesPerRow * height)

        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, drawn, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (png as Data, pixels)
    }


}

/// Makes the intro and outro for one export: the template's HTML card,
/// or the brand kit's built-in one, rendered by WebKit, with the native
/// card as the fallback.
struct CardMaker: Sendable {
    let brand: BrandKit
    let brandFolder: URL
    let look: TemplateLook?
    /// The template's folder, for its own card files.
    let templateFolder: URL?
    /// A personalised version's title card: drawn natively in place of
    /// the intro, so 40 versions don't need 40 WebKit renders.
    var personal: (headline: String, subline: String)?

    func plan(bodyDuration: Double) -> TemplatePlan {
        TemplatePlan(brand: brand, look: look, bodyDuration: bodyDuration)
    }

    func make(plan: TemplatePlan, size: CGSize, frameRate: Int) async -> BrandCardSet {
        var set = BrandCardSet.empty
        if let personal, plan.intro != nil {
            let logoData = brand.logoURL(in: brandFolder).flatMap { try? Data(contentsOf: $0) }
            set.intro = NativeCard(kind: .intro, brand: brand, logo: Self.decode(logoData),
                                   headline: personal.headline, subline: personal.subline)
        } else if let intro = plan.intro {
            set.intro = await card(.intro, choice: look?.intro, duration: intro.upperBound - intro.lowerBound,
                                   size: size, frameRate: frameRate)
        }
        if let outro = plan.outro {
            set.outro = await card(.outro, choice: look?.outro, duration: outro.upperBound - outro.lowerBound,
                                   size: size, frameRate: frameRate)
        }
        return set
    }

    private func card(_ kind: NativeCard.Kind, choice: TemplateLook.Card?, duration: Double,
                      size: CGSize, frameRate: Int) async -> any CardSource {
        let logoURL = brand.logoURL(in: brandFolder)
        let logoData = logoURL.flatMap { try? Data(contentsOf: $0) }
        let variables = CardVariables(brand: brand, logo: logoData,
                                      logoType: CardVariables.mimeType(forExtension: logoURL?.pathExtension ?? "png"))

        var html: URL?
        var readAccess: URL?
        if let choice, let folder = templateFolder, let url = TemplateLook.cardURL(choice, in: folder) {
            html = url
            readAccess = folder
        } else if let url = Bundle.main.url(forResource: kind == .intro ? "brand-intro" : "brand-outro", withExtension: "html") {
            html = url
            readAccess = url.deletingLastPathComponent()
        }

        if let html, let readAccess {
            do {
                return try await CardRenderer().render(card: html, readAccess: readAccess, variables: variables,
                                                       size: size, frameRate: frameRate, duration: duration)
            } catch is CancellationError {
                // Fall through to the native card; the export itself checks cancellation.
            } catch {
                NSLog("Vision One: HTML card failed, using the built-in one. \(error.localizedDescription)")
            }
        }
        return NativeCard(kind: kind, brand: brand, logo: Self.decode(logoData))
    }

    static func decode(_ data: Data?) -> CGImage? {
        guard let data, let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
