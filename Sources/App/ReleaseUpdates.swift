import Foundation

struct ReleaseVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ value: String) {
        let version = value.hasPrefix("v") ? value.dropFirst() : value[...]
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        guard components.count == 3, numbers.count == 3 else { return nil }
        parts = numbers
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

struct ReleaseUpdates {
    struct Update {
        let version: ReleaseVersion
        let url: URL
        let hasDownload: Bool
    }

    enum CheckError: LocalizedError {
        case invalidVersion
        case invalidResponse
        case rateLimited
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidVersion: return "The app or GitHub release has an unrecognised version number."
            case .invalidResponse: return "GitHub returned an unexpected response."
            case .rateLimited: return "GitHub’s update check limit was reached. Please try again later."
            case .httpStatus(let status): return "GitHub returned HTTP \(status)."
            }
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static let repository = "benjamindonnachie/mzt-player"
    private static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    static func check(installed: String) async throws -> Update? {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MZT-Player", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            throw CheckError.rateLimited
        }
        guard http.statusCode == 200 else { throw CheckError.httpStatus(http.statusCode) }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return try newerRelease(in: data, installed: installed, architecture: architecture)
    }

    static func newerRelease(in data: Data, installed: String, architecture: String) throws -> Update? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard let current = ReleaseVersion(installed), let latest = ReleaseVersion(release.tag_name) else {
            throw CheckError.invalidVersion
        }
        guard latest > current else { return nil }
        let filename = "MZT-Player-\(latest)-macOS-\(architecture).zip"
        let hasDownload = release.assets.contains { $0.name == filename && $0.state == "uploaded" }
        let releases = URL(string: "https://github.com/\(repository)/releases")!
        let tag = release.tag_name
        let url = hasDownload
            ? releases.appendingPathComponent("download").appendingPathComponent(tag).appendingPathComponent(filename)
            : releases.appendingPathComponent("tag").appendingPathComponent(tag)
        return Update(version: latest, url: url, hasDownload: hasDownload)
    }
}
