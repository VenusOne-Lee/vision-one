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

    /// Takes that still need a transcript, oldest first: they have a
    /// recording but no transcript.json, and were not marked as never
    /// transcribable (transcript-failed.json, such as a take with no sound).
    public func untranscribedTakes(fileManager: FileManager = .default) -> [Take] {
        takes(fileManager: fileManager)
            .filter {
                !fileManager.fileExists(atPath: $0.transcriptURL.path)
                    && !fileManager.fileExists(atPath: $0.transcriptFailedURL.path)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension Take {
    /// When the take was recorded, read back from its name ("Vision One
    /// 2026-10-27 at 10.53.12", maybe with " (2)"). Nil for a folder
    /// named some other way.
    public func recordedAt(timeZone: TimeZone = .current) -> Date? {
        let prefix = "Vision One "
        guard name.hasPrefix(prefix) else { return nil }
        let stamp = name.dropFirst(prefix.count).prefix("yyyy-MM-dd at HH.mm.ss".count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.date(from: String(stamp))
    }

    /// "Today at 14:41", "Yesterday at 09:05" or "27 Oct at 14:41", for
    /// the last take in the menu bar panel. Falls back to the folder name.
    public func shortLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = recordedAt(timeZone: calendar.timeZone) else { return name }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_GB")
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday at \(clock)"
        }
        time.dateFormat = "d MMM"
        return "\(time.string(from: date)) at \(clock)"
    }
}
