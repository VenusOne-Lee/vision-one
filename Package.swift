// swift-tools-version:6.0
import PackageDescription

// VisionOneKit holds the app's plain logic (recording state, file names,
// timecodes) so it can be tested with `swift test`, without Xcode or
// screen recording permission. The Mac app itself lives in App/ and is
// built from project.yml with XcodeGen.
let package = Package(
    name: "VisionOneKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VisionOneKit", targets: ["VisionOneKit"]),
    ],
    targets: [
        .target(
            name: "VisionOneKit",
            // The share page viewers open; SharePageBundle fills it in.
            resources: [.copy("Share/Page/share-page.html")]
        ),
        .testTarget(name: "VisionOneKitTests", dependencies: ["VisionOneKit"]),
    ],
    swiftLanguageModes: [.v5]
)
