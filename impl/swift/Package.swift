// swift-tools-version:5.9
import PackageDescription

// The core is a library and the CLI a thin executable on top, so the windowed
// frontends can link the same simulation later without a second copy.
let package = Package(
    name: "slimebench",
    targets: [
        .target(name: "SlimebenchCore"),
        .executableTarget(name: "slimebench", dependencies: ["SlimebenchCore"]),
    ]
)
