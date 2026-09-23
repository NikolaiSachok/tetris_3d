import Foundation

/// Reads and writes the profile as one JSON file. A damaged file is set aside and replaced by a fresh profile.
public struct ProfileStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Tetris3D/profile.json`
    public static var standard: ProfileStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProfileStore(url: support.appending(components: "Tetris3D", "profile.json"))
    }

    /// Where an unreadable profile is moved, so a bad write never silently destroys progress.
    public var quarantineURL: URL { url.deletingPathExtension().appendingPathExtension("corrupt.json") }

    public func load() -> Profile {
        guard let data = try? Data(contentsOf: url) else { return Profile() }
        do {
            return try decoder.decode(Profile.self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: quarantineURL)
            try? FileManager.default.moveItem(at: url, to: quarantineURL)
            return Profile()
        }
    }

    public func save(_ profile: Profile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(profile).write(to: url, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
