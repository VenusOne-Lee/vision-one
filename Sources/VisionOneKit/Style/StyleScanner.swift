import Foundation

/// Turns what the sampler measured into a `StyleProfile`. Plain maths, so
/// it runs the same on a file, a playing window, or in tests. See
/// docs/STYLE.md for how each trait is read.
public enum StyleScanner {
    public static func profile(from input: StyleInput, source: String) -> StyleProfile {
        let duration = max(input.duration, input.frames.last?.time ?? 0, 0.1)
        let cutTimes = Self.cuts(in: input.frames)
        let cutStats = cutStatistics(cutTimes, duration: duration)
        let read = input.frames.filter(\.wasRead)
        let captionResult = captions(in: read, duration: duration)
        let framingResult = framing(in: input.frames, cuts: cutTimes, duration: duration)
        let (palette, brightness) = Self.palette(from: input.frames)
        let cards = Self.cards(frames: read, cuts: cutTimes, sound: input.sound, duration: duration)
        let musicResult = music(sound: input.sound, envelope: input.envelope, rate: input.envelopeRate)
        let speechShare = Self.share(of: input.sound, duration: duration) { $0.hasSpeech }
        let hookResult = hook(frames: read, cuts: cutTimes, sound: input.sound)
        let format = VideoFormat.nearest(width: input.width, height: input.height)

        let energy = Self.energy(pace: cutStats.pace, captions: captionResult?.style,
                            punchIns: framingResult.punchInsPerMinute, music: musicResult)
        let purpose = Self.purpose(format: format, framing: framingResult.kind, pace: cutStats.pace, duration: duration)

        // Rough confidence: how much evidence each trait had.
        let readCount = Double(read.count)
        var confidence: [String: Double] = [:]
        confidence[StyleTraitID.cuts.rawValue] = clamp(Double(input.frames.count) / 120, 0.3, 0.95)
        confidence[StyleTraitID.captions.rawValue] = clamp(readCount / 30, 0.3, 0.9)
        confidence[StyleTraitID.framing.rawValue] = clamp(readCount / 30, 0.3, 0.9)
        confidence[StyleTraitID.zooms.rawValue] = clamp(Double(cutTimes.count) / 20, 0.3, 0.75)
        confidence[StyleTraitID.shape.rawValue] = input.width > 0 && input.height > 0 ? 1 : 0.3
        confidence[StyleTraitID.intro.rawValue] = input.sound.isEmpty ? 0.4 : 0.7
        confidence[StyleTraitID.outro.rawValue] = input.sound.isEmpty ? 0.4 : 0.6
        confidence[StyleTraitID.music.rawValue] = input.sound.isEmpty ? 0.2 : (musicResult?.bpm != nil ? 0.75 : 0.65)
        confidence[StyleTraitID.colours.rawValue] = palette.isEmpty ? 0 : 0.8

        return StyleProfile(
            source: source, duration: duration, width: input.width, height: input.height, format: format,
            cuts: cutStats, captions: captionResult, framing: framingResult, palette: palette,
            brightness: brightness, intro: cards.intro, outro: cards.outro, music: musicResult,
            speechShare: speechShare, hook: hookResult, energy: energy, purposeID: purpose,
            confidence: confidence)
    }

    // MARK: - Cuts

    /// Half the L1 distance between two signatures: 0 for the same colours,
    /// 1 for nothing in common.
    public static func difference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0.0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return min(sum / 2, 1)
    }

    /// Cut times, the PySceneDetect way: a frame is a cut when it differs
    /// from the last one by more than `threshold` and by `ratio` times the
    /// usual change around it, so busy footage doesn't count as cuts.
    public static func cuts(in frames: [StyleFrame], threshold: Double = 0.3, ratio: Double = 2.5,
                            window: Int = 4, minimumShot: Double = 0.4) -> [Double] {
        guard frames.count > 2 else { return [] }
        var diffs = [Double](repeating: 0, count: frames.count)
        for i in 1..<frames.count {
            diffs[i] = difference(frames[i - 1].signature, frames[i].signature)
        }
        var cuts: [Double] = []
        var last = -Double.infinity
        for i in 1..<frames.count where diffs[i] >= threshold {
            let lo = max(1, i - window), hi = min(frames.count - 1, i + window)
            let around = (lo...hi).filter { $0 != i }.map { diffs[$0] }
            let usual = around.isEmpty ? 0 : around.reduce(0, +) / Double(around.count)
            guard diffs[i] >= ratio * max(usual, 0.02) else { continue }
            let t = frames[i].time
            guard t - last >= minimumShot else { continue }
            cuts.append(t)
            last = t
        }
        return cuts
    }

    static func cutStatistics(_ cuts: [Double], duration: Double) -> StyleProfile.Cuts {
        let edges = [0] + cuts + [duration]
        let shots = zip(edges, edges.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        let median = shots.isEmpty ? duration : percentile(shots, 0.5)
        let average = shots.isEmpty ? duration : shots.reduce(0, +) / Double(shots.count)
        return StyleProfile.Cuts(times: cuts, perMinute: Double(cuts.count) / (duration / 60),
                                 medianShot: median, averageShot: average, pace: .from(medianShot: median))
    }

    // MARK: - Captions

    /// Words in the caption band (between 30% and 92% down, not the full
    /// width) on each read frame, joined top to bottom.
    static func captionText(_ boxes: [StyleTextBox]) -> String? {
        let band = boxes.filter { box in
            box.rect.centerY >= 0.3 && box.rect.centerY <= 0.92 && box.rect.width < 0.96
                && box.text.contains { $0.isLetter }
        }
        guard !band.isEmpty else { return nil }
        let text = band.sorted { $0.rect.y < $1.rect.y }.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
    }

    static func captions(in read: [StyleFrame], duration: Double) -> StyleProfile.Captions? {
        let textFrames = read.filter { $0.text != nil }
        guard textFrames.count >= 3 else { return nil }
        var seen: [(text: String, boxes: [StyleTextBox])] = []
        var changes = 0
        var previous: String?
        for frame in textFrames {
            guard let boxes = frame.text, let text = captionText(boxes) else {
                previous = nil
                continue
            }
            let key = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            if key != previous { changes += 1 }
            previous = key
            seen.append((text, boxes))
        }
        let coverage = Double(seen.count) / Double(textFrames.count)
        let changesPerMinute = Double(changes) / (duration / 60)
        // A logo or a title that stays put isn't a caption.
        guard coverage >= 0.25, changesPerMinute >= 6 else { return nil }

        let wordCounts = seen.map { Double($0.text.split(whereSeparator: \.isWhitespace).count) }
        let words = percentile(wordCounts, 0.5)
        let letters = seen.flatMap { $0.text.filter(\.isLetter) }
        let upper = letters.isEmpty ? 0 : Double(letters.filter(\.isUppercase).count) / Double(letters.count)
        let centres = seen.flatMap { item in
            item.boxes.filter { $0.rect.centerY >= 0.3 && $0.rect.centerY <= 0.92 }.map(\.rect.centerY)
        }
        let placement: StyleCaptionPlacement = percentile(centres, 0.5) < 0.68 ? .middle : .bottom

        let style: CaptionStyle
        switch words {
        case ..<3.5: style = .boldPop
        case ..<6.5: style = upper > 0.8 ? .keyword : .wordByWord
        default: style = .subtitle
        }
        return StyleProfile.Captions(style: style, wordsPerCaption: words, uppercase: upper > 0.8,
                                     placement: placement, coverage: coverage, changesPerMinute: changesPerMinute)
    }

    // MARK: - Framing and zooms

    static func framing(in frames: [StyleFrame], cuts: [Double], duration: Double) -> StyleProfile.Framing {
        let looked = frames.filter { $0.faces != nil }
        guard !looked.isEmpty else {
            return StyleProfile.Framing(kind: .screen, faceShare: 0, faceArea: 0, punchInsPerMinute: 0)
        }
        let biggest: [(time: Double, face: NormalisedRect)] = looked.compactMap { frame in
            guard let face = frame.faces?.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
            return (frame.time, face)
        }
        let share = Double(biggest.count) / Double(looked.count)
        let area = biggest.isEmpty ? 0 : percentile(biggest.map { $0.face.width * $0.face.height }, 0.5)
        let offCentre = biggest.isEmpty ? 0 : percentile(biggest.map {
            max(abs($0.face.centerX - 0.5), abs($0.face.centerY - 0.5))
        }, 0.5)

        let kind: StyleFramingKind
        if share >= 0.5, area >= 0.03 {
            kind = .talkingHead
        } else if share >= 0.4, area < 0.03, offCentre >= 0.25 {
            kind = .cameraBubble
        } else {
            kind = .screen
        }

        // Punch-ins: the same face, much bigger, in the next shot.
        let edges = [0] + cuts + [duration]
        var shotFaces: [NormalisedRect?] = []
        for (start, end) in zip(edges, edges.dropFirst()) {
            let inShot = biggest.filter { $0.time >= start && $0.time < end }.map { $0.face }
            guard !inShot.isEmpty else {
                shotFaces.append(nil)
                continue
            }
            let areas = inShot.map { $0.width * $0.height }
            let mid = percentile(areas, 0.5)
            shotFaces.append(inShot.min { abs($0.width * $0.height - mid) < abs($1.width * $1.height - mid) })
        }
        var punchIns = 0
        for (a, b) in zip(shotFaces, shotFaces.dropFirst()) {
            guard let a, let b else { continue }
            let grows = (b.width * b.height) / max(a.width * a.height, 0.0001)
            let near = abs(a.centerX - b.centerX) < 0.25 && abs(a.centerY - b.centerY) < 0.25
            if grows >= 1.3, near { punchIns += 1 }
        }
        return StyleProfile.Framing(kind: kind, faceShare: share, faceArea: area,
                                    punchInsPerMinute: Double(punchIns) / (duration / 60))
    }

    // MARK: - Colour

    /// Up to five colours covering most of the picture, biggest first, and
    /// how bright the picture is overall.
    static func palette(from frames: [StyleFrame], count: Int = 5) -> ([StyleProfile.Swatch], Double) {
        let points = frames.flatMap(\.colours)
        guard !points.isEmpty else { return ([], 0.5) }
        let brightness = points.map(\.luminance).reduce(0, +) / Double(points.count)

        // Seeds: the busiest buckets of a coarse 4×4×4 grid, so the result
        // is the same every run.
        var buckets: [Int: (sum: StyleRGB, n: Int)] = [:]
        for p in points {
            let key = Int(min(p.r * 4, 3)) * 16 + Int(min(p.g * 4, 3)) * 4 + Int(min(p.b * 4, 3))
            var entry = buckets[key] ?? (sum: StyleRGB(r: 0, g: 0, b: 0), n: 0)
            entry.sum.r += p.r
            entry.sum.g += p.g
            entry.sum.b += p.b
            entry.n += 1
            buckets[key] = entry
        }
        var centres = buckets.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.key < $1.key }
            .prefix(count)
            .map { StyleRGB(r: $0.value.sum.r / Double($0.value.n), g: $0.value.sum.g / Double($0.value.n),
                            b: $0.value.sum.b / Double($0.value.n)) }
        var members = [Int](repeating: 0, count: centres.count)
        for _ in 0..<8 {
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: centres.count)
            for p in points {
                var best = 0
                var bestDistance = Double.infinity
                for (i, c) in centres.enumerated() {
                    let d = p.distance(to: c)
                    if d < bestDistance { bestDistance = d; best = i }
                }
                sums[best].0 += p.r
                sums[best].1 += p.g
                sums[best].2 += p.b
                sums[best].3 += 1
            }
            for i in centres.indices where sums[i].3 > 0 {
                let n = Double(sums[i].3)
                centres[i] = StyleRGB(r: sums[i].0 / n, g: sums[i].1 / n, b: sums[i].2 / n)
            }
            members = sums.map { $0.3 }
        }
        var swatches: [(StyleRGB, Double)] = []
        for (i, c) in centres.enumerated() where members[i] > 0 {
            let weight = Double(members[i]) / Double(points.count)
            if let j = swatches.firstIndex(where: { $0.0.distance(to: c) < 0.08 }) {
                swatches[j].1 += weight
            } else {
                swatches.append((c, weight))
            }
        }
        let result = swatches.filter { $0.1 >= 0.02 }.sorted { $0.1 > $1.1 }
            .map { StyleProfile.Swatch(hex: $0.0.hex, share: ($0.1 * 100).rounded() / 100) }
        return (result, brightness)
    }

    // MARK: - Intro, outro, hook

    /// An opening or closing shot with words on it and nobody talking is a
    /// card. Without sound labels, only the words count.
    static func cards(frames read: [StyleFrame], cuts: [Double], sound: [StyleSoundWindow],
                      duration: Double) -> (intro: Double?, outro: Double?) {
        func isCard(from start: Double, to end: Double) -> Bool {
            let length = end - start
            guard length >= 0.8, length <= 8 else { return false }
            let inside = read.filter { $0.time >= start && $0.time < end && $0.text != nil }
            guard !inside.isEmpty else { return false }
            let withWords = inside.filter { !($0.text ?? []).isEmpty }.count
            guard Double(withWords) / Double(inside.count) >= 0.5 else { return false }
            let talking = overlap(of: sound.filter(\.hasSpeech), from: start, to: end)
            return talking / length < 0.3
        }
        guard let first = cuts.first, let last = cuts.last else { return (nil, nil) }
        let intro = isCard(from: 0, to: first) ? first : nil
        let outro = (last < duration && isCard(from: last, to: duration)) ? duration - last : nil
        return (intro.map { round1($0) }, outro.map { round1($0) })
    }

    static func hook(frames read: [StyleFrame], cuts: [Double], sound: [StyleSoundWindow]) -> StyleProfile.Hook {
        let speechStart = sound.first(where: \.hasSpeech)?.start
        let wordsEarly = read.contains { $0.time < 1 && !($0.text ?? []).isEmpty }
        let firstCut = cuts.first
        let kind: StyleHookKind
        if let s = speechStart, s < 1 {
            kind = .talksFirst
        } else if wordsEarly {
            kind = .textFirst
        } else if let c = firstCut, c < 2 {
            kind = .quickCut
        } else {
            kind = .slowOpen
        }
        return StyleProfile.Hook(kind: kind, speechStart: speechStart.map { round1($0) }, firstCut: firstCut.map { round1($0) })
    }

    // MARK: - Sound

    static func music(sound: [StyleSoundWindow], envelope: [Double], rate: Double) -> StyleProfile.Music? {
        let total = sound.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return nil }
        let musicShare = sound.filter(\.hasMusic).reduce(0) { $0 + $1.duration } / total
        guard musicShare >= 0.3 else { return nil }

        func mean(_ windows: [StyleSoundWindow]) -> Double? {
            windows.isEmpty ? nil : windows.map(\.loudness).reduce(0, +) / Double(windows.count)
        }
        // Speech windows carry voice plus music; music-only windows show
        // the bed on its own.
        var under: Double?
        if let voice = mean(sound.filter { $0.hasSpeech }), let bed = mean(sound.filter { $0.hasMusic && !$0.hasSpeech }) {
            under = max(0, (voice - bed).rounded())
        }
        return StyleProfile.Music(share: (musicShare * 100).rounded() / 100,
                                  bpm: tempo(envelope: envelope, rate: rate), underVoiceDB: under)
    }

    /// Beats a minute from a loudness envelope: autocorrelate the rises
    /// and pick the strongest lag between 70 and 180 bpm. Nil when there is
    /// no clear beat.
    public static func tempo(envelope: [Double], rate: Double) -> Double? {
        guard rate > 0, envelope.count >= Int(rate * 6) else { return nil }
        var onsets = [Double](repeating: 0, count: envelope.count)
        for i in 1..<envelope.count { onsets[i] = max(0, envelope[i] - envelope[i - 1]) }
        let mean = onsets.reduce(0, +) / Double(onsets.count)
        let centred = onsets.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }

        let minLag = Int((rate * 60 / 180).rounded(.down)), maxLag = Int((rate * 60 / 70).rounded(.up))
        guard minLag >= 1, maxLag < centred.count / 2 else { return nil }
        func score(_ lag: Int) -> Double {
            var sum = 0.0
            for i in lag..<centred.count { sum += centred[i] * centred[i - lag] }
            return sum / energy
        }
        var bestLag = minLag
        var best = -Double.infinity
        for lag in minLag...maxLag {
            let s = score(lag)
            if s > best { best = s; bestLag = lag }
        }
        guard best >= 0.2 else { return nil }
        // Refine between whole lags.
        var lag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let a = score(bestLag - 1), b = best, c = score(bestLag + 1)
            let bend = a - 2 * b + c
            if bend < 0 { lag += 0.5 * (a - c) / bend }
        }
        return (rate * 60 / lag).rounded()
    }

    // MARK: - Energy and purpose

    static func energy(pace: StylePace, captions: CaptionStyle?, punchIns: Double,
                       music: StyleProfile.Music?) -> Energy {
        var score = 0.0
        switch pace {
        case .slow: score += 0
        case .steady: score += 1
        case .fast: score += 2
        case .rapid: score += 3
        }
        if captions == .boldPop || captions == .keyword { score += 1 }
        if punchIns >= 2 { score += 1 }
        if let music { score += 0.5; if (music.bpm ?? 0) >= 115 { score += 0.5 } }
        switch score {
        case ..<1.5: return .calm
        case ..<3.5: return .lively
        default: return .viral
        }
    }

    static func purpose(format: VideoFormat, framing: StyleFramingKind, pace: StylePace, duration: Double) -> String {
        if format == .vertical, duration <= 75 { return "short" }
        if framing == .talkingHead { return "talkingHead" }
        if framing != .talkingHead, pace == .slow, duration > 120 { return "tutorial" }
        if framing != .talkingHead, duration > 60 { return "demo" }
        return "launch"
    }

    // MARK: - Helpers

    static func share(of sound: [StyleSoundWindow], duration: Double, where match: (StyleSoundWindow) -> Bool) -> Double {
        guard duration > 0 else { return 0 }
        let covered = sound.filter(match).reduce(0) { $0 + $1.duration }
        return min(1, (covered / duration * 100).rounded() / 100)
    }

    static func overlap(of windows: [StyleSoundWindow], from start: Double, to end: Double) -> Double {
        windows.reduce(0) { $0 + max(0, min($1.end, end) - max($1.start, start)) }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
