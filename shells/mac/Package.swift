// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AbraShell",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AbraShell",
            path: "Sources/AbraShell",
            exclude: ["Info.plist"],
            // Embed Info.plist (mic usage description, bundle id) into the
            // bare executable via a linker section. Required for the mic
            // permission prompt when launched outside a terminal.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AbraShell/Info.plist",
                ])
            ]
        )
    ]
)
