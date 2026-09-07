// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyMemoGuided",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "MyMemoGuided", targets: ["MyMemoGuided"])],
    targets: [
        .target(name: "MyMemoCore"),
        .target(name: "MyMemoExperience", dependencies: ["MyMemoCore"]),
        .executableTarget(name: "MyMemoGuided", dependencies: ["MyMemoCore", "MyMemoExperience"]),
        .testTarget(name: "MyMemoCoreTests", dependencies: ["MyMemoCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MyMemoExperienceTests", dependencies: ["MyMemoExperience", "MyMemoCore"])
    ], swiftLanguageModes: [.v5]
)
