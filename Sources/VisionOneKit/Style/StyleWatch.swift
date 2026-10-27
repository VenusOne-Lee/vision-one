import Foundation

/// "Watch it play": a link on a video site opens in a Vision One window,
/// plays, and is read as it plays. Nothing is downloaded. This holds the
/// plain parts (the page script, its reply, when to stop, where the
/// picture sits) so they can be tested without a web view.
public enum StyleWatch {
    /// What the page script reports about the biggest video on the page.
    public struct VideoState: Codable, Equatable, Sendable {
        public var found: Bool
        public var playing: Bool
        public var ended: Bool
        /// Seconds into the video.
        public var time: Double
        /// Zero when the page doesn't know (a live stream).
        public var duration: Double
        /// The video's own size in pixels.
        public var width: Double
        public var height: Double
        /// The element on the page, in CSS points from the top left of the
        /// web view.
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(found: Bool, playing: Bool = false, ended: Bool = false, time: Double = 0, duration: Double = 0,
                    width: Double = 0, height: Double = 0, x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0) {
            self.found = found
            self.playing = playing
            self.ended = ended
            self.time = time
            self.duration = duration
            self.width = width
            self.height = height
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ key: CodingKeys) -> Double {
                (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 }.map { $0.isFinite ? $0 : 0 } ?? 0
            }
            found = (try? c.decodeIfPresent(Bool.self, forKey: .found)).flatMap { $0 } ?? false
            playing = (try? c.decodeIfPresent(Bool.self, forKey: .playing)).flatMap { $0 } ?? false
            ended = (try? c.decodeIfPresent(Bool.self, forKey: .ended)).flatMap { $0 } ?? false
            time = number(.time)
            duration = number(.duration)
            width = number(.width)
            height = number(.height)
            x = number(.x)
            y = number(.y)
            w = number(.w)
            h = number(.h)
        }

        /// The script's JSON reply, or "not found" for anything else.
        public static func parse(_ reply: Any?) -> VideoState {
            guard let text = reply as? String, let data = text.data(using: .utf8),
                  let state = try? JSONDecoder().decode(VideoState.self, from: data) else {
                return VideoState(found: false)
            }
            return state
        }

        /// Where the picture is inside the element: videos keep their shape
        /// (object-fit: contain), so a vertical video in a wide box has bars
        /// either side, and those bars aren't the video.
        public var pictureRect: (x: Double, y: Double, width: Double, height: Double) {
            guard w > 0, h > 0, width > 0, height > 0 else { return (x, y, w, h) }
            let videoAspect = width / height
            if w / h > videoAspect {
                let fitted = h * videoAspect
                return (x + (w - fitted) / 2, y, fitted, h)
            } else {
                let fitted = w / videoAspect
                return (x, y + (h - fitted) / 2, w, fitted)
            }
        }
    }

    /// Finds the biggest video on the page, preferring one that's playing.
    static let findVideo = """
    const vids = Array.from(document.querySelectorAll('video')).filter(v => {
      const r = v.getBoundingClientRect(); return r.width > 80 && r.height > 80;
    });
    vids.sort((a, b) => {
      const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
      return rb.width * rb.height - ra.width * ra.height;
    });
    const v = vids.find(v => !v.paused && !v.ended) || vids[0];
    """

    /// Reports the video's state as JSON (see `VideoState`).
    public static let probeScript = """
    (() => {
    \(findVideo)
    if (!v) return JSON.stringify({found: false});
    const r = v.getBoundingClientRect();
    return JSON.stringify({found: true, playing: !v.paused && !v.ended && v.readyState > 2, ended: v.ended,
      time: v.currentTime, duration: isFinite(v.duration) ? v.duration : 0,
      width: v.videoWidth, height: v.videoHeight, x: r.left, y: r.top, w: r.width, h: r.height});
    })()
    """

    /// Starts the video from the top with sound, so music can be heard.
    /// Returns true when there was a video to start.
    public static let playScript = """
    (() => {
    \(findVideo)
    if (!v) return false;
    try { v.currentTime = 0; } catch (e) {}
    v.muted = false;
    v.loop = false;
    const p = v.play(); if (p && p.catch) p.catch(() => {});
    return true;
    })()
    """

    /// Pauses every video, so nothing keeps playing once reading is done.
    public static let pauseScript = "document.querySelectorAll('video').forEach(v => v.pause()); true"

    /// Follows the video's clock while it plays and says when to stop:
    /// at the end, after `StyleMeasure.maxSeconds`, or when a looping video
    /// starts over.
    public struct Progress: Equatable, Sendable {
        public private(set) var furthest: Double = 0
        public private(set) var duration: Double = 0
        public private(set) var done = false
        private var last: Double?

        public init() {}

        /// Seconds of video to read in all.
        public var target: Double {
            duration > 0 ? min(duration, StyleMeasure.maxSeconds) : StyleMeasure.maxSeconds
        }

        /// 0...1 for the progress bar.
        public var fraction: Double { min(1, furthest / max(target, 0.1)) }

        /// Takes the latest state; returns true once reading should stop.
        @discardableResult
        public mutating func update(_ state: VideoState) -> Bool {
            guard state.found, !done else { return done }
            if state.duration > 0 { duration = state.duration }
            if let last, furthest > 2, state.time < last - 1 {
                // Back near the start: it looped.
                done = true
                return done
            }
            last = state.time
            furthest = max(furthest, state.time)
            if state.ended || furthest >= StyleMeasure.maxSeconds || (duration > 0 && furthest >= duration - 0.3) {
                done = true
            }
            return done
        }
    }
}
