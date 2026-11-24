// swift-tools-version: 6.2
import Foundation
import PackageDescription

// UxPlay's protocol library uses OpenSSL's libcrypto. It is linked statically from Homebrew's openssl@3,
// so the built app does not depend on Homebrew at run time. Set OPENSSL_PREFIX to use another copy.
let openSSL = ProcessInfo.processInfo.environment["OPENSSL_PREFIX"] ?? "/opt/homebrew/opt/openssl@3"

let package = Package(
    name: "AirPlayViewer",
    defaultLocalization: "en",
    // Homebrew builds openssl@3 for the macOS version it runs on; this matches the copy on this Mac.
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WindowLayout", targets: ["WindowLayout"]),
        .executable(name: "AirPlayViewer", targets: ["AirPlayViewer"]),
    ],
    targets: [
        .target(name: "WindowLayout"),
        // libplist (LGPL-2.1), copied in by scripts/vendor-sources.sh.
        .target(
            name: "CPlist",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("libcnary/include"),
                .define("HAVE_TM_TM_GMTOFF"),
                .define("HAVE_TM_TM_ZONE"),
                .define("HAVE_TIMEGM"),
                .define("HAVE_STRPTIME"),
                .define("HAVE_STRNDUP"),
                .define("HAVE_LOCALTIME_R"),
                .define("HAVE_GMTIME_R"),
                .define("HAVE_MEMMEM"),
                .define("LIBPLIST_STATIC"),
                .define("PACKAGE_VERSION", to: "\"2.8.1\""),
                .unsafeFlags(["-w"]),
            ]
        ),
        // UxPlay's AirPlay protocol library (GPL-3.0), copied in by scripts/vendor-sources.sh,
        // behind the small interface in include/vpv_receiver.h.
        .target(
            name: "CAirPlay",
            dependencies: ["CPlist"],
            cSettings: [
                .headerSearchPath("uxplay"),
                .headerSearchPath("uxplay/playfair"),
                .headerSearchPath("uxplay/fairplay_v2"),
                .headerSearchPath("uxplay/llhttp"),
                .define("NOHOLD"),
                .define("EXTERNAL_DNS_SD"),
                .define("PLIST_210"),
                .define("PLIST_230"),
                .define("LIBPLIST_STATIC"),
                .unsafeFlags(["-w", "-I\(openSSL)/include"]),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .unsafeFlags(["\(openSSL)/lib/libcrypto.a"]),
            ]
        ),
        .target(name: "MirrorCore", dependencies: ["CAirPlay"]),
        .executableTarget(
            name: "AirPlayViewer",
            dependencies: ["MirrorCore", "WindowLayout"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "WindowLayoutTests", dependencies: ["WindowLayout"]),
        .testTarget(name: "AirPlayViewerTests", dependencies: ["AirPlayViewer"]),
        .target(name: "NativeMirrorTestSupport", dependencies: ["CAirPlay"], path: "Tests/NativeMirrorTestSupport"),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore", "NativeMirrorTestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
