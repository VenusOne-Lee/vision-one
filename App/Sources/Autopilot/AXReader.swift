import AppKit
import ApplicationServices
import VisionOneKit

/// One thing on screen, with the accessibility element behind it so
/// Autopilot can act on it.
struct AXNode {
    let element: AXUIElement
    let candidate: UICandidate
}

/// Reads an app's accessibility tree into `UICandidate`s for
/// `TargetMatcher`. Uses one batched call per element (attributes are
/// separate round trips to the app otherwise) and stops at a node limit,
/// so a huge web page can't stall a run.
enum AXReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility access, showing its prompt once.
    @discardableResult
    static func askForAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    /// Chrome, Electron apps and Dia only build their web content's tree
    /// when asked.
    static func wakeWebContent(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The app's focused (else main, else first) window.
    static func window(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window: AXUIElement = value(app, attribute) { return window }
        }
        let windows: [AXUIElement]? = value(app, kAXWindowsAttribute)
        return windows?.first
    }

    /// The element that has keyboard focus in `app`.
    static func focused(in app: AXUIElement) -> AXUIElement? {
        value(app, kAXFocusedUIElementAttribute)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func setSize(of window: AXUIElement, to size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func bundleID(of element: AXUIElement) -> String? {
        pid(of: element).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    /// What's under a screen point, from any app.
    static func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
        return result == .success ? element : nil
    }

    /// The element itself when it can be pressed or typed into, else the
    /// nearest ancestor that can (the link around a link's text).
    static func actionable(_ element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<5 {
            let role: String = value(current, kAXRoleAttribute) ?? ""
            if pressable.contains(role) || fields.contains(role) { return current }
            guard let parent: AXUIElement = value(current, kAXParentAttribute) else { break }
            current = parent
        }
        return element
    }

    static func candidate(for element: AXUIElement) -> UICandidate? {
        attributes(of: element).flatMap { candidate(from: $0) }
    }

    /// Everything worth naming in `window`, in reading order (breadth first).
    static func read(_ window: AXUIElement, limit: Int = 4000) -> [AXNode] {
        var nodes: [AXNode] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var next = 0
        while next < queue.count, nodes.count < limit, queue.count < limit * 4 {
            let (element, depth) = queue[next]
            next += 1
            guard let a = attributes(of: element) else { continue }
            if let c = candidate(from: a) { nodes.append(AXNode(element: element, candidate: c)) }
            if depth < 48 { queue.append(contentsOf: a.children.map { ($0, depth + 1) }) }
        }
        return nodes
    }

    // MARK: Acting

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    static func scrollToVisible(_ element: AXUIElement) {
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
    }

    // MARK: Reading

    static let pressable: Set<String> = ["AXButton", "AXLink", "AXPopUpButton", "AXMenuButton", "AXCheckBox",
                                         "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXTabButton",
                                         "AXDisclosureTriangle", "AXCell", "AXRow", "AXSlider", "AXIncrementor"]
    static let fields: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
    /// Shown, so "Point at" can find them, but never pressed.
    static let readable: Set<String> = ["AXStaticText", "AXImage", "AXHeading", "AXGroup", "AXCell"]

    struct Attributes {
        var role = ""
        var subrole = ""
        var title = ""
        var description = ""
        var value = ""
        var placeholder = ""
        var identifier: String?
        var frame: CGRect?
        var enabled = true
        var children: [AXUIElement] = []
    }

    private static let batch: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXPlaceholderValueAttribute, kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXEnabledAttribute, kAXChildrenAttribute,
    ]

    static func attributes(of element: AXUIElement) -> Attributes? {
        var raw: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, batch as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard result == .success, let values = raw as? [AnyObject], values.count == batch.count else { return nil }
        var a = Attributes()
        a.role = values[0] as? String ?? ""
        a.subrole = values[1] as? String ?? ""
        a.title = values[2] as? String ?? ""
        a.description = values[3] as? String ?? ""
        a.value = values[4] as? String ?? ""
        a.placeholder = values[5] as? String ?? ""
        a.identifier = (values[6] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let position = axValue(values[7]), let size = axValue(values[8]) {
            var point = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position, .cgPoint, &point)
            AXValueGetValue(size, .cgSize, &extent)
            a.frame = CGRect(origin: point, size: extent)
        }
        a.enabled = (values[9] as? Bool) ?? true
        a.children = (values[10] as? [AXUIElement]) ?? []
        return a
    }

    private static func candidate(from a: Attributes) -> UICandidate? {
        guard let frame = a.frame, frame.width >= 2, frame.height >= 2 else { return nil }
        let role = a.subrole == "AXSecureTextField" ? "AXSecureTextField" : a.role
        let isField = fields.contains(role)
        // A field is named by its label, never by what's typed in it.
        let name = [a.title, a.description, isField ? a.placeholder : a.value]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let worth = pressable.contains(role) || isField || (readable.contains(role) && !name.isEmpty)
            || a.identifier != nil
        guard worth else { return nil }
        return UICandidate(role: role, name: String(name.prefix(120)), identifier: a.identifier,
                           x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                           isEnabled: a.enabled, isSecure: role == "AXSecureTextField")
    }

    private static func axValue(_ object: AnyObject) -> AXValue? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = object as! AXValue
        return AXValueGetType(value) == .axError ? nil : value
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        return raw as? T
    }
}
