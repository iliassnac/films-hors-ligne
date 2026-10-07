// swift-tools-version: 5.9

// Swift Playgrounds "App Playground" package: opens in Xcode (Mac, install on
// iPhone/iPad) and in Swift Playgrounds (iPad, runs without a Mac).
// Xcode may rewrite this file when the signing team is set — that is expected.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "OfflineMovies",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .iOSApplication(
            name: "Films Hors Ligne",
            targets: ["AppModule"],
            bundleIdentifier: "local.offlinemovies.app",
            displayVersion: "1.0",
            bundleVersion: "1",
            accentColor: .presetColor(.indigo),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
