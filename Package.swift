// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LukaVapor",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-server-community/APNSwift", branch: "main"),
        .package(url: "https://github.com/kylebshr/dexcom-swift", branch: "main"),
        .package(url: "https://github.com/vapor/apns", from: "5.0.0"),
        .package(url: "https://github.com/vapor/redis.git", from: "4.14.0"),
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.2"),
    ],
    targets: [
        .executableTarget(
            name: "LukaVapor",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "APNS", package: "APNSwift"),
                .product(name: "Dexcom", package: "dexcom-swift"),
                .product(name: "VaporAPNS", package: "apns"),
                .product(name: "Redis", package: "redis"),
                .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "LukaVaporTests",
            dependencies: [
                .target(name: "LukaVapor"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
