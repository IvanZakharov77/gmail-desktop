// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GmailDesktop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GmailDesktop",
            path: "Sources/GmailDesktop"
        )
    ]
)
