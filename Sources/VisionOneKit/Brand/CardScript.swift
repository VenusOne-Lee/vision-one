import Foundation

/// What a template card is filled with. Brand values go in as CSS custom
/// properties and as text in elements marked `data-var="name"`, set with
/// textContent so a tagline can never turn into markup.
public struct CardVariables: Equatable, Sendable {
    /// Text values by name, for `data-var`.
    public var text: [String: String]
    /// CSS custom properties, set on the root element.
    public var css: [String: String]
    /// The logo as a data: URL, for `img[data-var="logo"]`. Cards can't
    /// read files outside their template folder, so the logo is inlined.
    public var logoDataURL: String?

    public init(brand: BrandKit, logo: Data? = nil, logoType: String = "image/png", title: String? = nil) {
        // A card with no name would be empty, so it falls back to ours.
        let trimmed = brand.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownName = trimmed.isEmpty ? "Vision One" : trimmed
        text = [
            "product": brand.name,
            "name": shownName,
            "tagline": brand.tagline,
            "site": brand.displaySite,
            "cta": brand.cta,
            "initial": brand.initial,
            "title": title ?? shownName,
        ]
        css = [
            "--ring": brand.ring.hexString,
            "--paper": RingColour.css(brand.paperHex),
            "--ink": RingColour.css(brand.inkHex),
            "--display-font": Self.fontStack(brand.fonts.display, fallback: "ui-sans-serif, system-ui, sans-serif"),
            "--body-font": Self.fontStack(brand.fonts.body, fallback: "ui-serif, Georgia, serif"),
        ]
        logoDataURL = logo.map { "data:\(logoType);base64,\($0.base64EncodedString())" }
    }

    /// A CSS font-family list with the name quoted safely.
    static func fontStack(_ name: String, fallback: String) -> String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : "\"\(cleaned)\", \(fallback)"
    }

    /// MIME type for a logo file.
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "svg": return "image/svg+xml"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }
}

/// The JavaScript the card renderer runs in the web view. Plain strings,
/// so they live here with tests rather than in the app.
public enum CardScript {
    /// Fills the card. Run once with `callAsyncJavaScript` and the
    /// arguments `text`, `css` and `logo` (null for none), then waits for
    /// fonts and images so the first frame isn't missing any.
    public static let prepare = """
    const root = document.documentElement;
    for (const [key, value] of Object.entries(css)) root.style.setProperty(key, value);
    document.querySelectorAll('[data-var]').forEach(el => {
      const name = el.dataset.var;
      if (name === 'logo') {
        if (el.tagName === 'IMG') {
          if (logo) { el.src = logo; } else { el.remove(); }
        }
        return;
      }
      if (Object.prototype.hasOwnProperty.call(text, name)) el.textContent = text[name];
    });
    document.querySelectorAll('[data-if]').forEach(el => {
      const name = el.dataset.if;
      const has = name === 'logo' ? !!logo : !!(text[name] && text[name].length);
      if (!has) el.remove();
    });
    document.querySelectorAll('[data-unless]').forEach(el => {
      const name = el.dataset.unless;
      const has = name === 'logo' ? !!logo : !!(text[name] && text[name].length);
      if (has) el.remove();
    });
    if (document.fonts && document.fonts.ready) await document.fonts.ready;
    await Promise.all(Array.from(document.images).map(img => img.decode ? img.decode().catch(() => null) : null));
    const comp = document.querySelector('[data-composition-id]');
    return {
      width: comp ? Number(comp.dataset.width || 0) : 0,
      height: comp ? Number(comp.dataset.height || 0) : 0,
      duration: comp ? Number(comp.dataset.duration || 0) : 0
    };
    """

    /// Moves every animation to `t` seconds and shows only the clips that
    /// are on at `t`, the way HyperFrames seeks: CSS and Web Animations
    /// through getAnimations(), GSAP timelines in window.__timelines, and
    /// window.__hf.seek if the card has its own. Run with the argument `t`.
    public static let seek = """
    const ms = t * 1000;
    for (const a of document.getAnimations()) { a.pause(); a.currentTime = ms; }
    const timelines = window.__timelines || {};
    for (const key of Object.keys(timelines)) {
      const tl = timelines[key];
      if (tl && typeof tl.seek === 'function') {
        if (typeof tl.pause === 'function') tl.pause();
        tl.seek(t, false);
      }
    }
    if (window.__hf && typeof window.__hf.seek === 'function') window.__hf.seek(t);
    document.querySelectorAll('.clip[data-start]').forEach(el => {
      const start = parseFloat(el.dataset.start) || 0;
      const length = parseFloat(el.dataset.duration);
      const on = t >= start && (isNaN(length) || t < start + length);
      el.style.visibility = on ? '' : 'hidden';
    });
    return true;
    """

    /// Network rule for the web view: block everything that isn't a local
    /// file or inline data, so a template can't phone home or change
    /// between renders.
    public static let blockNetworkRules = """
    [{"trigger":{"url-filter":"^http://"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^https://"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^ws://"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^wss://"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
    {"trigger":{"url-filter":"^ftps://"},"action":{"type":"block"}}]
    """

    /// Frame times for a card: one per frame from 0, quantised to the
    /// frame grid so two renders of the same card match.
    public static func frameTimes(duration: Double, frameRate: Int) -> [Double] {
        let fps = max(1, frameRate)
        let count = max(1, Int((max(0, duration) * Double(fps)).rounded()))
        return (0..<count).map { Double($0) / Double(fps) }
    }
}

/// Accumulates paint evidence across the whole animation. A fade may end
/// on a flat frame even though earlier frames contain the intended card.
public struct CardPaintEvidence: Sendable {
    public private(set) var hasPaint = false
    public init() {}
    public mutating func observe(_ pixels: Data) {
        guard !hasPaint, pixels.count >= 4 else { return }
        hasPaint = pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            let first = (bytes[0], bytes[1], bytes[2])
            for i in stride(from: 0, to: bytes.count - 3, by: 4) {
                if (bytes[i], bytes[i + 1], bytes[i + 2]) != first { return true }
            }
            return false
        }
    }
}
