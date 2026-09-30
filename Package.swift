// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MikerosoftTaskbar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "taskbar-swift", targets: ["TaskbarApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/mikecann/prompter-kit.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TaskbarApp",
            dependencies: [
                .product(name: "PrompterKit", package: "prompter-kit")
            ],
            path: "Sources/TaskbarApp"
        ),
        .testTarget(
            name: "TaskbarAppTests",
            dependencies: ["TaskbarApp"],
            path: "tests/TaskbarAppTests"
        )
    ]
)
