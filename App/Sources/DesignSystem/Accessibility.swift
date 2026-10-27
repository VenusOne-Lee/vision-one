import SwiftUI

/// The keyboard focus ring: 2 pt selection blue, 2 pt outside the
/// control, on every custom control. Shows only while the control has
/// keyboard focus (Tab with Keyboard navigation on in System Settings).
private struct FocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .overlay {
                if isFocused {
                    shape.inset(by: -3)
                        .strokeBorder(Theme.selection, lineWidth: Theme.Stroke.focus)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Draws the design's focus ring around a custom control.
    func focusRing<S: InsettableShape>(_ shape: S) -> some View {
        modifier(FocusRing(shape: shape))
    }

    /// Makes a hit area at least `Theme.Size.hitMin` square without
    /// changing how the control looks.
    func minimumHitTarget() -> some View {
        frame(minWidth: Theme.Size.hitMin, minHeight: Theme.Size.hitMin)
            .contentShape(Rectangle())
    }

    /// An animation that turns off with Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(Theme.Motion.reduced ? nil : animation, value: value)
    }
}
