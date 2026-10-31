import Testing
import Foundation
@testable import MonitorCore

/// Release JSON shaped like GitHub's `releases/latest` answer (only the fields the app reads, plus noise).
func releaseJSON(tag: String, assets: [(name: String, url: String)] = [],
                 page: String = "https://github.com/primemindai/macmonitor/releases/tag/v1.2.0",
                 body: String = "Fixes.") -> Data {
    let obj: [String: Any] = [
        "tag_name": tag, "name": "MacMonitor \(tag)", "html_url": page, "body": body,
        "draft": false, "prerelease": false, "id": 1,
        "assets": assets.map { ["name": $0.name, "browser_download_url": $0.url, "size": 1, "content_type": "application/zip"] },
    ]
    return try! JSONSerialization.data(withJSONObject: obj)
}

/// A fetch that serves fixed bytes per URL and counts every request. Unknown URLs answer 404.
final class StubFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    /// Final URL to report for a request (stands in for a redirect).
    private var landsOn: [String: String]
    private(set) var requests: [URLRequest] = []

    init(_ files: [String: Data] = [:], landsOn: [String: String] = [:]) { self.files = files; self.landsOn = landsOn }

    var count: Int { lock.withLock { requests.count } }

    var fetch: UpdateFeed.Fetch {
        { [self] req in
            let key = req.url!.absoluteString
            let (data, final) = lock.withLock {
                requests.append(req)
                return (files[key], landsOn[key].flatMap(URL.init(string:)) ?? req.url!)
            }
            let resp = HTTPURLResponse(url: final, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data ?? Data(), resp)
        }
    }
}

func updateDefaults() -> UserDefaults {
    let name = "macmonitor.tests.update.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Update check: the version compare, the JSON, the throttle and the off switch.
@Suite struct UpdateCheckTests {
    /// A wrong compare either nags forever (shows an update for the version already installed) or misses a real one.
    @Test(arguments: [
        ("1.9.0", "v1.10.0", true),     // numeric per part, not text
        ("1.1.0", "v1.2.0", true),
        ("1.1.0", "1.2.0", true),       // tag without the v
        ("1.2.0", "v1.2", false),       // 1.2 == 1.2.0: no nag
        ("1.2", "v1.2.0", false),
        ("1.2.0", "v1.1.9", false),     // older release: no downgrade offer
        ("1.10.0", "v1.9.9", false),
        ("1.1.0", "latest", false),     // tag it cannot read: no badge
        ("1.1.0", "v1.2.0-beta.1", false),
        ("1.1.0", "", false),
    ])
    func badgeOnlyForANewerRelease(current: String, tag: String, badge: Bool) async {
        let stub = StubFetch([UpdateFeed.latestURL.absoluteString: releaseJSON(tag: tag)])
        let c = UpdateChecker(currentVersion: current, settings: UpdateSettings(defaults: updateDefaults()), fetch: stub.fetch)
        let r = await c.checkNow()
        if case .available = r { #expect(badge, "badge shown for \(tag) over \(current)") } else { #expect(!badge, "no badge for \(tag) over \(current): \(r)") }
    }

    /// The request must carry nothing about the Mac: a plain GET with only our User-Agent added.
    @Test func checkSendsAPlainGet() async throws {
        let stub = StubFetch([UpdateFeed.latestURL.absoluteString: releaseJSON(tag: "v1.0.0")])
        _ = await UpdateChecker(currentVersion: "1.1.0", settings: UpdateSettings(defaults: updateDefaults()), fetch: stub.fetch).checkNow()
        let req = try #require(stub.requests.first)
        #expect(req.httpMethod == "GET")
        #expect(req.httpBody == nil)
        #expect(req.url == UpdateFeed.latestURL)
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "MacMonitor/1.1.0")
        let headers = Set((req.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(headers.isSubset(of: ["user-agent", "accept-language"]), "extra headers: \(headers)")
    }

    /// Off means no network call at all, at launch or later; on is the default; on checks at most once a day.
    @Test func throttleAndOffSwitch() async {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        let d = updateDefaults()
        let s = UpdateSettings(defaults: d)
        #expect(s.enabled, "checking is on by default")

        // Off: nothing is fetched, even at launch, even when never checked.
        s.enabled = false
        let off = StubFetch([UpdateFeed.latestURL.absoluteString: releaseJSON(tag: "v9.0.0")])
        let cOff = UpdateChecker(currentVersion: "1.1.0", settings: s, fetch: off.fetch, now: { t0 })
        let launch = await cOff.checkIfDue(atLaunch: true), later = await cOff.checkIfDue(atLaunch: false)
        #expect(launch == .skipped && later == .skipped)
        #expect(off.count == 0)
        #expect(UpdateSettings(defaults: d).enabled == false, "the off switch is stored")

        // On: launch checks, then nothing more until 24 hours have passed.
        s.enabled = true
        let on = StubFetch([UpdateFeed.latestURL.absoluteString: releaseJSON(tag: "v9.0.0")])
        func at(_ hours: Double) -> UpdateChecker {
            let t = t0.addingTimeInterval(hours * 3_600)
            return UpdateChecker(currentVersion: "1.1.0", settings: s, fetch: on.fetch, now: { t })
        }
        _ = await at(0).checkIfDue(atLaunch: true)
        #expect(on.count == 1)
        #expect(UpdateSettings(defaults: d).lastCheck == t0, "last check time is stored")
        let early = await at(23).checkIfDue(atLaunch: false)
        #expect(early == .skipped)
        #expect(on.count == 1)
        _ = await at(24).checkIfDue(atLaunch: false)
        #expect(on.count == 2)
        // A clock set back days must not stop checks until it catches up.
        _ = await at(-72).checkIfDue(atLaunch: false)
        #expect(on.count == 3)
    }

    /// A check that fails (say at login, before Wi-Fi is up) must not block the next one for a whole day.
    @Test func failedCheckIsRetriedWithinTheHour() async {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000), t1 = t0.addingTimeInterval(3_600)
        let s = UpdateSettings(defaults: updateDefaults())
        let offline: UpdateFeed.Fetch = { _ in throw URLError(.notConnectedToInternet) }
        let first = await UpdateChecker(currentVersion: "1.1.0", settings: s, fetch: offline, now: { t0 }).checkIfDue(atLaunch: true)
        guard case .failed = first else { Issue.record("offline check gave \(first)"); return }
        #expect(s.lastCheck == nil, "a failed check must not count as checked")

        let online = StubFetch([UpdateFeed.latestURL.absoluteString: releaseJSON(tag: "v1.2.0")])
        let second = await UpdateChecker(currentVersion: "1.1.0", settings: s, fetch: online.fetch, now: { t1 }).checkIfDue(atLaunch: false)
        #expect(online.count == 1)
        guard case .available = second else { Issue.record("retry gave \(second)"); return }
        #expect(s.lastCheck == t1)
    }
}

/// Security of what gets downloaded: only GitHub over https, and only with a matching SHA-256.
@Suite struct UpdateSafetyTests {
    /// A non-GitHub or plain-http asset URL would let anyone on the path hand us an app to run.
    @Test(arguments: [
        ("https://github.com/primemindai/macmonitor/releases/download/v1.2.0/MacMonitor-1.2.0.zip", true),
        ("https://objects.githubusercontent.com/github-production-release-asset/1/2", true),
        ("https://release-assets.githubusercontent.com/github-production-release-asset/1/2", true),
        ("http://github.com/primemindai/macmonitor/releases/download/v1.2.0/MacMonitor-1.2.0.zip", false),
        ("https://evil.example/MacMonitor-1.2.0.zip", false),
        ("https://github.com.evil.example/MacMonitor-1.2.0.zip", false),
        ("https://evilgithub.com/MacMonitor-1.2.0.zip", false),
        ("https://github.com@evil.example/MacMonitor-1.2.0.zip", false),
        ("https://user:pw@github.com/MacMonitor-1.2.0.zip", false),
        ("https://github.com:8443/MacMonitor-1.2.0.zip", false),
        ("ftp://github.com/MacMonitor-1.2.0.zip", false),
        ("file:///tmp/MacMonitor-1.2.0.zip", false),
    ])
    func assetURLsMustBeGitHubOverHTTPS(url: String, allowed: Bool) throws {
        #expect(UpdateFeed.isAllowedAssetURL(URL(string: url)!) == allowed)
        let data = releaseJSON(tag: "v1.2.0", assets: [("MacMonitor-1.2.0.zip", url), ("MacMonitor-1.2.0.zip.sha256", url + ".sha256")])
        let r = try #require(UpdateFeed.parse(data))
        #expect((r.zipURL != nil) == allowed)
        #expect((r.checksumURL != nil) == allowed)
    }

    /// The release page link and a URL inside the notes are never used as the download.
    @Test func picksOnlyTheNamedAssetsAndAGitHubPage() throws {
        let notes = "Get it at https://evil.example/MacMonitor-1.2.0.zip"
        let data = releaseJSON(tag: "v1.2.0", assets: [
            ("MacMonitor-1.1.0.zip", "https://github.com/a/b/releases/download/v1.1.0/MacMonitor-1.1.0.zip"),
            ("Other.zip", "https://github.com/a/b/releases/download/v1.2.0/Other.zip"),
        ], page: "https://evil.example/release", body: notes)
        let r = try #require(UpdateFeed.parse(data))
        #expect(r.versionText == "1.2.0")
        #expect(r.zipName == "MacMonitor-1.2.0.zip")
        #expect(r.zipURL == nil && r.checksumURL == nil)
        #expect(r.pageURL == UpdateFeed.releasesPage, "a non-GitHub page link falls back to our releases page")
        #expect(r.notes == notes)
    }

    /// A tampered zip, a checksum for some other file, or no checksum at all must refuse the install.
    @Test func checksumMustMatch() throws {
        let zip = Data("abc".utf8)
        let good = Checksum.sha256Hex(zip)
        let name = "MacMonitor-1.2.0.zip"
        let cases: [(String?, UpdateError?)] = [
            ("\(good)  \(name)\n", nil),                       // shasum -a 256 output
            ("\(good) *\(name)\n", nil),                       // shasum binary mode
            ("\(good.uppercased())  \(name)", nil),
            ("\(good)\n", nil),                                // bare hash
            ("\(good)  .build/release-zip/\(name)\n", nil),    // path before the name
            (nil, .checksumMissing),
            ("", .checksumMissing),
            ("not a hash", .checksumMissing),
            ("\(String(repeating: "0", count: 64))  \(name)", .checksumMismatch),
            ("\(good)  MacMonitor-1.1.0.zip", .checksumMismatch),
        ]
        for (text, want) in cases {
            do {
                try Checksum.verify(zip, shasum: text, fileName: name)
                #expect(want == nil, "accepted \(text ?? "nil")")
            } catch let e as UpdateError {
                #expect(e == want, "\(text ?? "nil") gave \(e)")
            }
        }
    }
}

/// Where the app may replace itself, and the swap that must never leave the user with no app.
@Suite struct UpdateInstallPlaceTests {
    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A translocated, read-only or non-.app location must not even try to install.
    @Test func installOnlyWhereItIsSafe() throws {
        let root = try tempDir("place")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("ro").path)
                try? FileManager.default.removeItem(at: root) }
        let ok = root.appendingPathComponent("Apps/MacMonitor.app")
        try FileManager.default.createDirectory(at: ok, withIntermediateDirectories: true)
        #expect(InstallPlace.check(bundleURL: ok) == .ok)

        let ro = root.appendingPathComponent("ro/MacMonitor.app")
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("ro").path)
        #expect(InstallPlace.check(bundleURL: ro) == .notWritable)

        let trans = URL(fileURLWithPath: "/private/var/folders/xy/abc/T/AppTranslocation/1234-ABCD/d/MacMonitor.app")
        #expect(InstallPlace.check(bundleURL: trans) == .translocated)

        #expect(InstallPlace.check(bundleURL: root.appendingPathComponent("Apps")) == .notAnApp)
    }

    /// A path with shell syntax in it must reach `open` as one plain argument and never run as a command.
    @Test func relaunchNeverRunsTheAppPath() throws {
        let root = try tempDir("relaunch")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("ran").path
        // A pid that has already exited, so the wait loop ends at once.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        for path in ["/x/$(touch \(marker))/MacMonitor.app", "/x/\"; touch \(marker); \"/MacMonitor.app", "/x/`touch \(marker)`/MacMonitor.app"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // /bin/echo stands in for /usr/bin/open: it prints the argument it was given.
            p.arguments = UpdateInstaller.relaunchArguments(pid: gone.processIdentifier, appPath: path, opener: "/bin/echo")
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            #expect(text == path + "\n", "open got a different argument")
            #expect(!FileManager.default.fileExists(atPath: marker), "the path ran as a command: \(path)")
        }
    }
}

/// The whole "Update now" pipeline with no network: a real ad-hoc signed app, zipped with ditto, served by a stub.
@Suite(.serialized) struct UpdatePipelineTests {
    let zipURL = "https://github.com/primemindai/macmonitor/releases/download/v1.2.0/MacMonitor-1.2.0.zip"

    @discardableResult func run(_ args: [String], in dir: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        if let dir { p.currentDirectoryURL = dir }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A tiny app bundle: Info.plist, a copied system binary as its executable, ad-hoc signed.
    func makeApp(at app: URL, version: String, bundleID: String = "com.macmonitor.app") throws {
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "MacMonitor",
                                    "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("MacMonitor"))
        try run(["/usr/bin/codesign", "--force", "-s", "-", app.path])
    }

    func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    struct World {
        var root: URL, apps: URL, current: URL, work: URL, kept: URL, zip: Data, sha: Data
    }

    /// Builds the new release exactly as scripts/release.sh does (ditto zip, `shasum -a 256` beside it),
    /// and an old 1.1.0 app in a temp "Applications" folder.
    func world() throws -> World {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mm-update-\(UUID().uuidString)")
        let build = root.appendingPathComponent("build"), apps = root.appendingPathComponent("Applications")
        let work = root.appendingPathComponent("work"), kept = root.appendingPathComponent("kept")
        for d in [build, apps, work, kept] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try makeApp(at: build.appendingPathComponent("MacMonitor.app"), version: "1.2.0")
        try run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "MacMonitor.app", "MacMonitor-1.2.0.zip"], in: build)
        let sha = try run(["/usr/bin/shasum", "-a", "256", "MacMonitor-1.2.0.zip"], in: build)
        let current = apps.appendingPathComponent("MacMonitor.app")
        try makeApp(at: current, version: "1.1.0")
        return World(root: root, apps: apps, current: current, work: work, kept: kept,
                     zip: try Data(contentsOf: build.appendingPathComponent("MacMonitor-1.2.0.zip")), sha: Data(sha.utf8))
    }

    func release(withChecksum: Bool = true) throws -> ReleaseInfo {
        var assets = [("MacMonitor-1.2.0.zip", zipURL)]
        if withChecksum { assets.append(("MacMonitor-1.2.0.zip.sha256", zipURL + ".sha256")) }
        return try #require(UpdateFeed.parse(releaseJSON(tag: "v1.2.0", assets: assets)))
    }

    func installer(_ w: World, _ stub: StubFetch) -> UpdateInstaller {
        UpdateInstaller(fetch: stub.fetch, workRoot: w.work, keepFolder: w.kept)
    }

    func isEmpty(_ dir: URL) -> Bool { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty }

    @Test func installsOverTheOldAppAndCleansUp() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let stub = StubFetch([zipURL: w.zip, zipURL + ".sha256": w.sha])
        let outcome = try await installer(w, stub).run(try release(), over: w.current)
        #expect(outcome == .installed(w.current))
        #expect(version(of: w.current) == "1.2.0")
        _ = try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", w.current.path])
        #expect(isEmpty(w.work), "temp files left behind")
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.apps.path) == ["MacMonitor.app"], "backup left in Applications")
    }

    /// Every way the download can be wrong leaves the old app exactly as it was, and no temp files.
    @Test(arguments: ["tampered checksum", "missing checksum", "tampered zip", "wrong bundle id", "wrong version", "broken signature",
                      "app is a symlink", "redirect off GitHub"])
    func badDownloadNeverTouchesTheOldApp(_ problem: String) async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        var files = [zipURL: w.zip, zipURL + ".sha256": w.sha]
        var landsOn: [String: String] = [:]
        var rel = try release()
        switch problem {
        case "tampered checksum": files[zipURL + ".sha256"] = Data((String(repeating: "a", count: 64) + "  MacMonitor-1.2.0.zip\n").utf8)
        case "missing checksum": rel = try release(withChecksum: false)
        case "tampered zip": var z = w.zip; z[z.count / 2] ^= 0xFF; files[zipURL] = z
        case "wrong bundle id", "wrong version", "broken signature":
            // A matching checksum, but the app inside is not one we may install.
            let other = w.root.appendingPathComponent("other")
            let app = other.appendingPathComponent("MacMonitor.app")
            try makeApp(at: app, version: problem == "wrong version" ? "1.1.5" : "1.2.0",
                        bundleID: problem == "wrong bundle id" ? "com.example.other" : "com.macmonitor.app")
            if problem == "broken signature" { try Data("added after signing".utf8).write(to: app.appendingPathComponent("Contents/MacOS/extra")) }
            try run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "MacMonitor.app", "MacMonitor-1.2.0.zip"], in: other)
            files[zipURL] = try Data(contentsOf: other.appendingPathComponent("MacMonitor-1.2.0.zip"))
            files[zipURL + ".sha256"] = Data(try run(["/usr/bin/shasum", "-a", "256", "MacMonitor-1.2.0.zip"], in: other).utf8)
        case "app is a symlink":
            // A good signed 1.2.0 app, but the zip holds only a symlink to it (zip -y keeps links; ditto would follow it).
            let other = w.root.appendingPathComponent("other")
            let real = other.appendingPathComponent("elsewhere/MacMonitor.app")
            try makeApp(at: real, version: "1.2.0")
            try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("MacMonitor.app"), withDestinationURL: real)
            try run(["/usr/bin/zip", "-q", "-y", "MacMonitor-1.2.0.zip", "MacMonitor.app"], in: other)
            files[zipURL] = try Data(contentsOf: other.appendingPathComponent("MacMonitor-1.2.0.zip"))
            files[zipURL + ".sha256"] = Data(try run(["/usr/bin/shasum", "-a", "256", "MacMonitor-1.2.0.zip"], in: other).utf8)
        case "redirect off GitHub": landsOn[zipURL] = "https://evil.example/MacMonitor-1.2.0.zip"
        default: Issue.record("unknown case")
        }
        let want: [String: UpdateError] = [
            "tampered checksum": .checksumMismatch, "missing checksum": .checksumMissing, "tampered zip": .checksumMismatch,
            "wrong bundle id": .wrongApp("different bundle id"), "wrong version": .wrongApp("version does not match the release"),
            "broken signature": .signatureInvalid, "app is a symlink": .wrongApp("no MacMonitor.app inside"),
            "redirect off GitHub": .unsafeURL,
        ]
        let stub = StubFetch(files, landsOn: landsOn)
        await #expect(throws: want[problem]!) { try await installer(w, stub).run(rel, over: w.current) }
        #expect(version(of: w.current) == "1.1.0", "old app changed after: \(problem)")
        _ = try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", w.current.path])
        #expect(isEmpty(w.work), "temp files left after: \(problem)")
        #expect(isEmpty(w.kept))
    }

    /// An http or non-GitHub asset URL is refused before any byte is fetched.
    @Test func unsafeAssetURLIsNeverFetched() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        var rel = try release()
        rel.zipURL = URL(string: "http://github.com/primemindai/macmonitor/releases/download/v1.2.0/MacMonitor-1.2.0.zip")
        let stub = StubFetch()
        await #expect(throws: UpdateError.unsafeURL) { try await installer(w, stub).run(rel, over: w.current) }
        #expect(stub.count == 0)
        #expect(version(of: w.current) == "1.1.0")
    }

    /// In a folder this user cannot write, the verified app is kept aside for the user to drag in; the old one stays.
    @Test func readOnlyFolderKeepsTheDownloadAside() async throws {
        let w = try world()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.apps.path)
            try? FileManager.default.removeItem(at: w.root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: w.apps.path)
        let stub = StubFetch([zipURL: w.zip, zipURL + ".sha256": w.sha])
        let outcome = try await installer(w, stub).run(try release(), over: w.current)
        guard case .downloadedOnly(let kept, let place) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(place == .notWritable)
        #expect(kept.path.hasPrefix(w.kept.path))
        #expect(version(of: kept) == "1.2.0")
        #expect(version(of: w.current) == "1.1.0")
        #expect(isEmpty(w.work))
    }

    /// Counts the swap's moves across threads.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
    }

    /// A failing swap never leaves the user with no app. A permission refusal (macOS App Management) puts the old app
    /// back and hands over the checked new copy instead.
    @Test(arguments: ["move in fails", "move in and restore fail", "App Management blocks moving out", "App Management blocks moving in",
                      "App Management blocks moving in and back"])
    func failedSwapNeverLosesTheOldApp(_ problem: String) async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let denied = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        let broken = CocoaError(.fileWriteUnknown)
        // The swap's moves in order: 1 old app out, 2 new app in, 3 old app back.
        let fails: [Int: Error] = switch problem {
        case "move in fails": [2: broken]
        case "move in and restore fail": [2: broken, 3: broken]
        case "App Management blocks moving out": [1: denied]
        case "App Management blocks moving in and back": [2: denied, 3: denied]
        default: [2: denied]
        }
        let calls = Counter()
        var inst = installer(w, StubFetch([zipURL: w.zip, zipURL + ".sha256": w.sha]))
        inst.swapMove = { from, to in
            if let e = fails[calls.next()] { throw e }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let rel = try release()

        switch problem {
        case "move in fails":
            await #expect(throws: UpdateError.swapFailed) { try await inst.run(rel, over: w.current) }
            #expect(version(of: w.current) == "1.1.0")
        case "move in and restore fail", "App Management blocks moving in and back":
            let blocked = problem.hasPrefix("App Management")
            do {
                let out = try await inst.run(rel, over: w.current)
                Issue.record("expected an error, got \(out)")
            } catch let UpdateError.oldAppSaved(at: path, newCopy: newCopy) {
                #expect(path.hasPrefix(w.kept.path), "old app saved outside the keep folder: \(path)")
                #expect(version(of: URL(fileURLWithPath: path)) == "1.1.0", "the old app is not where the error says")
                _ = try run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path])
                // Refused for permission: the checked new copy must survive too, and the message must say how to allow it.
                #expect((newCopy != nil) == blocked)
                if let newCopy {
                    #expect(newCopy.hasPrefix(w.kept.path))
                    #expect(version(of: URL(fileURLWithPath: newCopy)) == "1.2.0", "the new copy is not where the error says")
                    #expect(UpdateError.oldAppSaved(at: path, newCopy: newCopy).message.contains("App Management"))
                }
            }
        default:
            let out = try await inst.run(rel, over: w.current)
            guard case .downloadedOnly(let kept, let place) = out else { Issue.record("got \(out)"); return }
            #expect(place == .blocked)
            #expect(place.advice.contains("App Management"))
            #expect(version(of: kept) == "1.2.0")
            #expect(version(of: w.current) == "1.1.0")
        }
        #expect(isEmpty(w.work), "temp files left after: \(problem)")
    }
}
