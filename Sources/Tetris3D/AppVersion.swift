import Foundation

/// Version and build number stamped into Info.plist by scripts/build_app.sh.
enum AppVersion {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    /// "V1.2.0 · BUILD 57", or a development marker when running outside a packaged app (`swift run`).
    static var display: String {
        guard let version, let build else { return "DEVELOPMENT BUILD" }
        return "V\(version) · BUILD \(build)"
    }
}
