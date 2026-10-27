import Foundation

extension TakeLibrary {
    /// Every take that has a recording, newest first. Take names start
    /// with the date and time, so newest first is reverse name order.
    public func takes(fileManager: FileManager = .default) -> [Take] {
        let folders = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .map(Take.init(folder:))
            .filter { fileManager.fileExists(atPath: $0.screenURL.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }
}
