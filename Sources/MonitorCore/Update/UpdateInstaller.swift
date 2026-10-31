import Foundation

/// Whether the running app may replace itself where it is.
public enum InstallPlace: Equatable, Sendable {
    case ok
    /// macOS runs a downloaded app from a random read-only copy until it is moved (App Translocation).
    case translocated
    /// The folder holding the app, or the app itself, is not writable by this user.
    case notWritable
    /// Not running from a .app bundle (for example a `swift build` binary).
    case notAnApp

    public static func check(bundleURL: URL, fileManager: FileManager = .default) -> InstallPlace {
        let path = bundleURL.standardizedFileURL.path
        if MCPSetup.isTranslocated(path) { return .translocated }
        guard bundleURL.pathExtension == "app" else { return .notAnApp }
        // Moving a folder out of its parent needs write access to both the parent and the folder itself.
        let parent = bundleURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent), fileManager.isWritableFile(atPath: path) else { return .notWritable }
        return .ok
    }

    /// What the user should do when the app cannot update itself here.
    public var advice: String {
        switch self {
        case .ok: return ""
        case .translocated:
            return "macOS is running MacMonitor from a temporary copy. Drag the new MacMonitor into your Applications folder, then open it from there."
        case .notWritable:
            return "MacMonitor cannot write to the folder it is in. Quit MacMonitor, then drag the new MacMonitor over the old one."
        case .notAnApp:
            return "This copy is not running from MacMonitor.app, so it cannot replace itself. Use the new MacMonitor.app instead."
        }
    }
}

/// "Update now": download the release zip and its checksum, verify, unpack, check the app, swap it in.
///
/// The app downloads these files itself, so macOS puts no quarantine flag on them and the new copy opens
/// with no Gatekeeper prompt. That is why every step here refuses anything it cannot prove: a GitHub https
/// URL, a matching SHA-256, our bundle id and version, and a valid code signature.
public struct UpdateInstaller: Sendable {
    public enum Step: String, Sendable {
        case downloading = "Downloading..."
        case verifying = "Checking the download..."
        case unpacking = "Unpacking..."
        case installing = "Installing..."
    }

    public enum Outcome: Equatable, Sendable {
        /// The new version is at this path. The caller relaunches it.
        case installed(URL)
        /// Verified, but not installed in place; the new app is kept at this path for the user.
        case downloadedOnly(URL, InstallPlace)
    }

    public static let bundleID = "com.macmonitor.app"

    public var fetch: UpdateFeed.Fetch
    /// Parent for the temp work folder. nil: a system temp folder on the same disk as the app, so moves are renames.
    public var workRoot: URL?
    /// Where a verified app goes when it cannot be installed in place.
    public var keepFolder: URL
    /// The running version, for the User-Agent header only.
    public var appVersion: String

    public init(fetch: @escaping UpdateFeed.Fetch = UpdateFeed.liveFetch, workRoot: URL? = nil,
                keepFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory,
                appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") {
        self.fetch = fetch
        self.workRoot = workRoot
        self.keepFolder = keepFolder
        self.appVersion = appVersion
    }

    /// Runs off the calling actor. Temp files are always removed; the old app is only touched by `swap`.
    public func run(_ release: ReleaseInfo, over appURL: URL, step: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> Outcome {
        guard let zipURL = release.zipURL else { throw UpdateError.noDownload }
        guard let sumURL = release.checksumURL else { throw UpdateError.checksumMissing }
        guard UpdateFeed.isAllowedAssetURL(zipURL), UpdateFeed.isAllowedAssetURL(sumURL) else { throw UpdateError.unsafeURL }

        let fm = FileManager.default
        let work = try makeWorkFolder(near: appURL)
        defer { try? fm.removeItem(at: work) }

        step(.downloading)
        let zip = try await download(zipURL, timeout: 300)
        let sum = try await download(sumURL, timeout: 30)

        step(.verifying)
        try Checksum.verify(zip, shasum: String(data: sum, encoding: .utf8), fileName: release.zipName)

        step(.unpacking)
        let zipFile = work.appendingPathComponent(release.zipName)
        try zip.write(to: zipFile)
        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard Self.tool("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path]) else { throw UpdateError.unzipFailed }
        let newApp = unpacked.appendingPathComponent("MacMonitor.app")
        try Self.checkApp(newApp, version: release.version)

        let place = InstallPlace.check(bundleURL: appURL)
        guard place == .ok else {
            let dest = try keep(newApp, version: release.versionText)
            return .downloadedOnly(dest, place)
        }
        step(.installing)
        let backupDir = work.appendingPathComponent("backup")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try Self.swap(current: appURL, new: newApp, backup: backupDir.appendingPathComponent(appURL.lastPathComponent),
                      move: { try fm.moveItem(at: $0, to: $1) })
        return .installed(appURL)
    }

    private func download(_ url: URL, timeout: TimeInterval) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await fetch(UpdateFeed.request(url, appVersion: appVersion, timeout: timeout)) }
        catch { throw UpdateError.network(error.localizedDescription) }
        // The URL the bytes really came from, after redirects.
        guard let final = resp.url, UpdateFeed.isAllowedAssetURL(final) else { throw UpdateError.unsafeURL }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return data
    }

    /// A fresh folder for this run. The default sits on the app's disk so the swap is two renames.
    private func makeWorkFolder(near appURL: URL) throws -> URL {
        let fm = FileManager.default
        let parent: URL
        if let workRoot {
            parent = workRoot
        } else {
            parent = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL.deletingLastPathComponent(), create: true))
                ?? fm.temporaryDirectory
        }
        let u = parent.appendingPathComponent("macmonitor-update-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Moves the verified app to `keepFolder/MacMonitor-<version>/MacMonitor.app` (a free name if that exists).
    private func keep(_ app: URL, version: String) throws -> URL {
        let fm = FileManager.default
        var folder = keepFolder.appendingPathComponent("MacMonitor-\(version)")
        var n = 2
        while fm.fileExists(atPath: folder.path) { folder = keepFolder.appendingPathComponent("MacMonitor-\(version) (\(n))"); n += 1 }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(app.lastPathComponent)
        try fm.moveItem(at: app, to: dest)
        return dest
    }

    /// Bundle id, version and `codesign --verify --deep --strict` on the unpacked app.
    static func checkApp(_ app: URL, version: AppVersion) throws {
        // A real folder, not a symlink pointing somewhere else.
        let type = (try? FileManager.default.attributesOfItem(atPath: app.path))?[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw UpdateError.wrongApp("no MacMonitor.app inside") }
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.wrongApp("no MacMonitor.app inside")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.wrongApp("different bundle id") }
        guard let v = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), v == version else {
            throw UpdateError.wrongApp("version does not match the release")
        }
        guard tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw UpdateError.signatureInvalid }
    }

    /// Old app to the backup, new app to the old path, then drop the backup.
    /// If the new app cannot be moved in, the backup goes back, so the user is never left with no app.
    public static func swap(current: URL, new: URL, backup: URL, move: (URL, URL) throws -> Void) throws {
        do { try move(current, backup) } catch { throw UpdateError.swapFailed(restored: true) }
        do {
            try move(new, current)
        } catch {
            let restored = (try? move(backup, current)) != nil
            throw UpdateError.swapFailed(restored: restored)
        }
        try? FileManager.default.removeItem(at: backup)
    }

    /// `/bin/sh` arguments that wait for this process to quit, then open the app at `appPath`.
    /// The pid and path are passed as arguments, never pasted into the script, so no path needs quoting.
    public static func relaunchArguments(pid: Int32, appPath: String) -> [String] {
        ["-c", #"i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; exec /usr/bin/open "$2""#,
         "macmonitor-relaunch", String(pid), appPath]
    }

    /// Runs a system tool and waits. True when it exits 0.
    static func tool(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
