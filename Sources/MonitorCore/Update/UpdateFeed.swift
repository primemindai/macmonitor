import Foundation
import CryptoKit

/// A version like 1.2.0, compared number by number: 1.10.0 is newer than 1.9.0, and 1.2 equals 1.2.0.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// "1.2.0", "v1.2.0" or "1.2". Anything else (a suffix like "-beta", letters, empty parts) is nil.
    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let pieces = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var out: [Int] = []
        for p in pieces {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        parts = out
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private static func padded(_ a: AppVersion, _ b: AppVersion) -> ([Int], [Int]) {
        let n = max(a.parts.count, b.parts.count)
        return (a.parts + Array(repeating: 0, count: n - a.parts.count), b.parts + Array(repeating: 0, count: n - b.parts.count))
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { let (x, y) = padded(a, b); return x == y }
    public static func < (a: AppVersion, b: AppVersion) -> Bool { let (x, y) = padded(a, b); return x.lexicographicallyPrecedes(y) }
}

/// The newest release, read from GitHub's `releases/latest` answer.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    /// The tag without its "v", as release.sh names the zip ("1.2.0").
    public var versionText: String
    public var title: String
    /// Release notes as plain text. Shown only; a link in here is never followed.
    public var notes: String
    /// The release page on github.com (the Download link).
    public var pageURL: URL
    /// "MacMonitor-<version>.zip".
    public var zipName: String
    /// Set only when the asset is on an allowed GitHub host over https.
    public var zipURL: URL?
    public var checksumURL: URL?
    /// "MacMonitor-<version>.zip.sig": the Ed25519 signature of the zip. Same host rule as the zip.
    public var signatureURL: URL? = nil
}

/// Where updates come from and which URLs may be trusted.
public enum UpdateFeed {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let latestURL = URL(string: "https://api.github.com/repos/primemindai/macmonitor/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/primemindai/macmonitor/releases/latest")!
    /// Release downloads start on github.com and redirect to one of GitHub's asset hosts.
    public static let assetHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    /// https only, an exact allowed host, default port, no user or password in the URL.
    public static func isAllowedAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), assetHosts.contains(host) else { return false }
        return url.port == nil && url.user == nil && url.password == nil
    }

    /// A redirect may only land on GitHub's API or asset hosts, over https.
    public static func isAllowedRedirect(_ url: URL) -> Bool {
        if isAllowedAssetURL(url) { return true }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == latestURL.host && url.port == nil && url.user == nil
    }

    /// A plain GET. The only header added is our User-Agent, plus a fixed Accept-Language so the system's
    /// language list is not sent. Nothing about the Mac goes out.
    public static func request(_ url: URL, appVersion: String, timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "GET"
        r.setValue("MacMonitor/\(appVersion)", forHTTPHeaderField: "User-Agent")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        return r
    }

    /// The release, or nil when the answer is not JSON or its tag is not a version we can read.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let version = AppVersion(tag) else { return nil }
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let zipName = "MacMonitor-\(text).zip"
        var assets: [String: URL] = [:]
        for a in obj["assets"] as? [[String: Any]] ?? [] {
            if let name = a["name"] as? String, let s = a["browser_download_url"] as? String, let u = URL(string: s) { assets[name] = u }
        }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
        return ReleaseInfo(
            version: version, versionText: text,
            title: (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "MacMonitor \(text)",
            notes: obj["body"] as? String ?? "",
            pageURL: page.flatMap { $0.scheme == "https" && $0.host?.lowercased() == "github.com" ? $0 : nil } ?? releasesPage,
            zipName: zipName,
            zipURL: assets[zipName].flatMap { isAllowedAssetURL($0) ? $0 : nil },
            checksumURL: assets[zipName + ".sha256"].flatMap { isAllowedAssetURL($0) ? $0 : nil })
    }

    /// URLSession with no cookies or cache, which refuses any redirect off GitHub.
    public static let liveFetch: Fetch = { request in
        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            // nil stops here; the caller then sees the 3xx and refuses it.
            guard let u = request.url, UpdateFeed.isAllowedRedirect(u) else { return nil }
            return request
        }
    }
}

/// The SHA-256 check between the zip and its `.sha256` asset.
public enum Checksum {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `shasum -a 256` output: "<64 hex>  <file>" (or " *<file>", or a bare hash).
    /// When a file name is given, it must be `fileName` (a path before it is fine).
    /// Returns the hash, "" for a different file, or nil when there is no hash.
    static func expectedHash(_ text: String, fileName: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = fields.first, first.count == 64, first.allSatisfy(\.isHexDigit) else { return nil }
        if fields.count == 2 {
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if (name as NSString).lastPathComponent != fileName { return "" }
        }
        return first.lowercased()
    }

    /// Throws `checksumMissing` when there is no readable hash and `checksumMismatch` when it differs.
    public static func verify(_ data: Data, shasum: String?, fileName: String) throws {
        guard let shasum, let want = expectedHash(shasum, fileName: fileName) else { throw UpdateError.checksumMissing }
        guard want == sha256Hex(data) else { throw UpdateError.checksumMismatch }
    }
}

/// Everything that can stop an update, with the line shown to the user.
public enum UpdateError: Error, Equatable, Sendable {
    case noDownload
    case unsafeURL
    case http(Int)
    case network(String)
    case checksumMissing
    case checksumMismatch
    case unzipFailed
    case wrongApp(String)
    case signatureInvalid
    /// The release has no `.sig` file (the Ed25519 release signature, not the app's code signature).
    case releaseSignatureMissing
    /// The `.sig` file is unreadable or was not made with the MacMonitor project key for these exact bytes.
    case releaseSignatureMismatch
    /// The swap failed and the current version is back in place.
    case swapFailed
    /// The swap failed and the old app could not go back; it was saved at this path instead.
    /// `newCopy` is set when macOS refused for permission: the checked new version was kept there too.
    case oldAppSaved(at: String, newCopy: String?)
    /// As above, but saving to Downloads failed too, so the old app is still in a temp folder macOS may clear.
    case oldAppOnlyInTemp(at: String)

    public var message: String {
        switch self {
        case .noDownload: return "This release has no download for MacMonitor."
        case .unsafeURL: return "The download is not on GitHub over a secure link, so it was not used."
        case .http(let code): return "GitHub answered with error \(code)."
        case .network(let why): return "Could not reach GitHub: \(why)"
        case .checksumMissing: return "The release has no checksum file, so the download cannot be checked. Nothing was installed."
        case .checksumMismatch: return "The download does not match its checksum. Nothing was installed."
        case .unzipFailed: return "The download could not be unpacked. Nothing was installed."
        case .wrongApp(let why): return "The download is not the expected MacMonitor (\(why)). Nothing was installed."
        case .signatureInvalid: return "The downloaded app failed its code signature check. Nothing was installed."
        case .releaseSignatureMissing:
            return "The release has no signature file, so MacMonitor cannot tell who made it. Nothing was installed."
        case .releaseSignatureMismatch:
            return "The download is not signed with the MacMonitor project key. Nothing was installed."
        case .swapFailed: return "Could not replace the app. The current version is still in place."
        case .oldAppSaved(let path, nil):
            return "Could not replace the app or put the old one back. Your old MacMonitor is saved at \(path). Drag it into your Applications folder."
        case .oldAppSaved(let path, let newCopy?):
            return "macOS did not let MacMonitor replace itself or put the old one back. Your old MacMonitor is saved at \(path), and the checked new version is at \(newCopy). Allow MacMonitor under System Settings > Privacy & Security > App Management, or drag the new copy into Applications by hand."
        case .oldAppOnlyInTemp(let path):
            return "Could not replace the app or put the old one back. Your old MacMonitor is in a temporary folder at \(path). Copy it somewhere safe now, then drag it into your Applications folder."
        }
    }
}

/// When the automatic check runs: never when switched off, at launch, then once a day.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 86_400

    public static func isDue(enabled: Bool, lastCheck: Date?, now: Date, atLaunch: Bool) -> Bool {
        guard enabled else { return false }
        if atLaunch { return true }
        guard let lastCheck else { return true }
        // abs: a clock set far back must not block checks until it catches up.
        return abs(now.timeIntervalSince(lastCheck)) >= interval
    }
}

/// The Settings switch and the last check time, in UserDefaults.
public final class UpdateSettings: @unchecked Sendable {
    public static let enabledKey = "updateCheckEnabled"
    public static let lastCheckKey = "updateLastCheck"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// On unless the user turned it off.
    public var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }
}

/// Asks GitHub for the newest release and compares it with the running version.
public struct UpdateChecker: Sendable {
    public enum Result: Equatable, Sendable {
        /// Not asked: switched off, not due, or this build has no version.
        case skipped
        case upToDate(latest: AppVersion)
        case available(ReleaseInfo)
        case failed(String)
    }

    public let currentVersion: String?
    public let settings: UpdateSettings
    public let fetch: UpdateFeed.Fetch
    public let now: @Sendable () -> Date

    public init(currentVersion: String?, settings: UpdateSettings, fetch: @escaping UpdateFeed.Fetch = UpdateFeed.liveFetch,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.currentVersion = currentVersion
        self.settings = settings
        self.fetch = fetch
        self.now = now
    }

    /// The automatic check. Makes no network call when the switch is off or a check ran in the last 24 hours.
    public func checkIfDue(atLaunch: Bool) async -> Result {
        guard UpdateSchedule.isDue(enabled: settings.enabled, lastCheck: settings.lastCheck, now: now(), atLaunch: atLaunch) else { return .skipped }
        return await checkNow()
    }

    /// "Check now": asks right away. A build with no version (a plain `swift build`) never asks.
    public func checkNow() async -> Result {
        guard let currentVersion, let current = AppVersion(currentVersion) else { return .skipped }
        do {
            let (data, resp) = try await fetch(UpdateFeed.request(UpdateFeed.latestURL, appVersion: currentVersion))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed(UpdateError.http((resp as? HTTPURLResponse)?.statusCode ?? 0).message)
            }
            guard let release = UpdateFeed.parse(data) else { return .failed("GitHub's answer had no version MacMonitor can read.") }
            // Stamped only on a good answer: a check that fails (say at login, before Wi-Fi is up) is retried
            // on the next hourly wake instead of waiting a whole day.
            settings.lastCheck = now()
            return release.version > current ? .available(release) : .upToDate(latest: release.version)
        } catch {
            return .failed(UpdateError.network(error.localizedDescription).message)
        }
    }
}
