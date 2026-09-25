// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HerdwickCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HerdrAPI", targets: ["HerdrAPI"]),
        .library(name: "HerdwickSSH", targets: ["HerdwickSSH"]),
        .library(name: "HerdrDemo", targets: ["HerdrDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        // Transport-agnostic herdr protocol: models, client, connection supervisor.
        .target(name: "HerdrAPI"),
        // SSH implementation of `CommandRunner` on Apple's swift-nio-ssh.
        .target(
            name: "HerdwickSSH",
            dependencies: [
                "HerdrAPI",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // Test-only `CommandRunner` that spawns local processes (Linux/macOS).
        .target(name: "HerdrTestSupport", dependencies: ["HerdrAPI"]),
        .target(name: "HerdrDemo", dependencies: ["HerdrAPI"], resources: [.copy("Scenarios")]),
        .testTarget(name: "HerdrAPITests", dependencies: ["HerdrAPI", "HerdrTestSupport"], resources: [.copy("Screens")]),
        .testTarget(
            name: "HerdrDemoTests",
            dependencies: ["HerdrDemo", "HerdrAPI"]
        ),
        .testTarget(
            name: "HerdwickSSHTests",
            dependencies: [
                "HerdwickSSH", "HerdrAPI",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
