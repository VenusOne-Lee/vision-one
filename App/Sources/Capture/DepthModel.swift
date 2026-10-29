import AppKit
import CoreImage
import CoreML
import Vision
import VisionOneKit

/// Gets Apple's Core ML build of Depth Anything V2 (small, Apache 2.0,
/// about 50 MB) the first time "Move with me" is used with a picture, and
/// compiles it once. Rooms drawn by Vision One don't need it: they come in
/// layers already.
@MainActor
final class DepthModelStore: ObservableObject {
    static let shared = DepthModelStore()

    enum State: Equatable {
        case missing
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private init() {
        state = DepthEstimator.isInstalled ? .ready : .missing
    }

    /// Downloads and compiles the model unless it's here or on its way.
    func prepare() {
        switch state {
        case .ready, .downloading: return
        case .missing, .failed: break
        }
        state = .downloading
        Task {
            do {
                try await Self.install()
                state = .ready
            } catch {
                state = .failed("Couldn't get the depth model: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static let base = URL(string: "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage/")!
    /// The standard inside of an .mlpackage.
    private nonisolated static let files = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
    ]

    private nonisolated static func install() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("VisionOneDepth-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let package = work.appendingPathComponent("DepthAnythingV2SmallF16.mlpackage", isDirectory: true)
        for file in files {
            let (downloaded, response) = try await URLSession.shared.download(from: base.appendingPathComponent(file))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "the download stopped at \(file)"])
            }
            let target = package.appendingPathComponent(file)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: downloaded, to: target)
        }
        let compiled = try await MLModel.compileModel(at: package)
        try fm.createDirectory(at: CameraBackground.modelsFolder, withIntermediateDirectories: true)
        let destination = DepthEstimator.compiledURL
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: compiled, to: destination)
    }
}

/// Runs the depth model on a picture. Each picture's result is kept, so
/// moving the bubble or exporting again doesn't run it twice.
final class DepthEstimator: @unchecked Sendable {
    static let shared = DepthEstimator()

    struct Depth {
        /// Bigger is nearer, in the model's own units, origin at zero.
        let map: CIImage
        let min: Float
        let max: Float
        /// Cut points for the near layers (`DepthLayers.thresholds`).
        let cuts: [Float]
    }

    static var compiledURL: URL {
        CameraBackground.modelsFolder.appendingPathComponent("DepthAnythingV2SmallF16.mlmodelc", isDirectory: true)
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: compiledURL.path) }

    private let lock = NSLock()
    private var model: VNCoreMLModel?
    private var cache: [String: Depth] = [:]
    private let reader = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

    /// Nil when the model isn't installed yet, or the picture is flat.
    /// `key` names the picture (its file name) for the cache.
    func depth(of picture: CGImage, key: String) -> Depth? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let model = loadModel() else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cgImage: picture).perform([request])
        } catch {
            return nil
        }
        guard var map = Self.image(from: request.results?.first) else { return nil }
        map = BackgroundRenderer.grey(map)
        map = map.transformed(by: CGAffineTransform(translationX: -map.extent.minX, y: -map.extent.minY))
        // Back to the picture's shape (the model squashes it to its own).
        map = map.transformed(by: CGAffineTransform(scaleX: CGFloat(picture.width) / map.extent.width,
                                                    y: CGFloat(picture.height) / map.extent.height))
        let values = sample(map)
        guard let cuts = DepthLayers.thresholds(values),
              let lo = values.filter(\.isFinite).min(), let hi = values.filter(\.isFinite).max() else { return nil }
        let depth = Depth(map: map, min: lo, max: hi, cuts: cuts)
        cache[key] = depth
        return depth
    }

    private func loadModel() -> VNCoreMLModel? {
        if let model { return model }
        guard Self.isInstalled else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let ml = try? MLModel(contentsOf: Self.compiledURL, configuration: configuration),
              let vision = try? VNCoreMLModel(for: ml) else { return nil }
        model = vision
        return vision
    }

    /// The depth as a picture, whether the model hands back an image or
    /// an array of numbers.
    private static func image(from observation: VNObservation?) -> CIImage? {
        if let pixels = observation as? VNPixelBufferObservation {
            return CIImage(cvPixelBuffer: pixels.pixelBuffer)
        }
        guard let array = (observation as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              array.shape.count >= 2 else { return nil }
        let height = array.shape[array.shape.count - 2].intValue
        let width = array.shape[array.shape.count - 1].intValue
        guard width > 0, height > 0, array.count >= width * height else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent32Float,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    row[x] = array[y * width + x].floatValue
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // Arrays run top to bottom; Core Image runs bottom to top.
        let image = CIImage(cvPixelBuffer: buffer)
        return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -image.extent.height))
    }

    /// The map's values on a small grid, for the layer cut points.
    private func sample(_ map: CIImage) -> [Float] {
        let side: CGFloat = 96
        let small = map.transformed(by: CGAffineTransform(scaleX: side / map.extent.width, y: side / map.extent.height))
        let n = Int(side)
        var pixels = [Float](repeating: .nan, count: n * n * 4)
        reader.render(small, toBitmap: &pixels, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                      format: .RGBAf, colorSpace: nil)
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
