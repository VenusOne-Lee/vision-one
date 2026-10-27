import Foundation

extension TakePlan {
    /// Remembers what a new take is for: Home's pick, saved into the take
    /// when recording stops so later changes on Home don't rewrite it.
    /// Leaves an existing plan alone, and writes nothing for "Just record"
    /// (no pick) or an unknown id. Returns the plan it wrote, if any.
    @discardableResult
    public static func stamp(_ take: Take, purposeID: String?,
                             fileManager: FileManager = .default) throws -> TakePlan? {
        guard !fileManager.fileExists(atPath: take.planURL.path),
              let id = purposeID, let purpose = Purpose.named(id) else { return nil }
        let plan = TakePlan(purpose: purpose)
        try plan.write(for: take)
        return plan
    }
}
