import SwiftUI

/// Suppresses decorative motion while retaining the same state changes.
@MainActor
enum WorkspaceMotion {
    static func constrain(_ transaction: inout Transaction, reduced: Bool) {
        guard reduced else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }

    static func perform(reduced: Bool, _ changes: () -> Void) {
        if reduced {
            var transaction = Transaction(animation: nil)
            constrain(&transaction, reduced: true)
            withTransaction(transaction, changes)
        } else {
            withAnimation(Theme.Motion.enter, changes)
        }
    }

    static func verify() throws {
        var reduced = Transaction(animation: .default)
        constrain(&reduced, reduced: true)
        try MediaVerification.require(reduced.animation == nil && reduced.disablesAnimations,
                                      "Reduce Motion did not disable workspace animation")
        var normal = Transaction(animation: .default)
        constrain(&normal, reduced: false)
        try MediaVerification.require(normal.animation != nil && !normal.disablesAnimations,
                                      "Normal workspace motion was unexpectedly disabled")
        var changes = 0
        perform(reduced: true) { changes += 1 }
        perform(reduced: false) { changes += 1 }
        try MediaVerification.require(changes == 2, "Motion preference suppressed state changes")
    }
}
