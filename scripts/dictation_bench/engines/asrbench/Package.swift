// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "asrbench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio", revision: "503b4bd1bbf7220882de39fe8ae6716aae4132da")],
    targets: [.executableTarget(name: "asrbench", dependencies: ["FluidAudio"], swiftSettings: [.swiftLanguageMode(.v5)])]
)
