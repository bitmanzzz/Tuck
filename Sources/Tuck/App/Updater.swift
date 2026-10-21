import AppKit
import Security

/// Checks GitHub Releases for a newer Tuck and installs it in place.
///
/// An update is installed only if it is signed by the same identity as the
/// running copy. That keeps out tampered downloads and, because macOS ties
/// privacy permissions to the signature, means users keep their permissions.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let notes: String
        let page: URL
        let archive: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private static let latestRelease = URL(string: "https://api.github.com/repos/bitmanzzz/Tuck/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/bitmanzzz/Tuck/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks once a day while automatic checks are on.
    func startAutomaticChecks(settings: Settings) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue(settings: settings) }
        }
        // Give the menu bar a moment to settle after launch.
        Task {
            try? await Task.sleep(for: .seconds(10))
            checkIfDue(settings: settings)
        }
    }

    private func checkIfDue(settings: Settings) {
        guard settings.checkForUpdates else { return }
        let last = defaults.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    /// Looks for a newer release and offers it. Automatic checks stay silent
    /// unless there is something new that the user hasn't skipped.
    func check(userInitiated: Bool) async {
        guard status != .checking, status != .installing else { return }
        status = .checking
        let release: Release
        do {
            release = try await fetchLatestRelease()
            defaults.set(Date(), forKey: Keys.lastCheck)
        } catch {
            status = .failed(error.localizedDescription)
            if userInitiated { showError() }
            return
        }

        guard Self.isVersion(release.version, newerThan: Self.currentVersion) else {
            status = .upToDate
            if userInitiated {
                alert(
                    title: String(localized: "Tuck is up to date"),
                    message: String(localized: "Version \(Self.currentVersion) is the latest version."),
                    buttons: [String(localized: "OK")]
                )
            }
            return
        }
        status = .available(release.version)
        if !userInitiated, defaults.string(forKey: Keys.skippedVersion) == release.version { return }
        offer(release)
    }

    private func offer(_ release: Release) {
        var message = String(localized: "You have version \(Self.currentVersion). Tuck will download the update, replace itself and relaunch.")
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            message += "\n\n" + (notes.count > 600 ? notes.prefix(600) + "…" : notes)
        }
        let response = alert(
            title: String(localized: "Tuck \(release.version) is available"),
            message: message,
            buttons: [String(localized: "Install and Relaunch"), String(localized: "Later"), String(localized: "Skip This Version")]
        )
        switch response {
        case .alertFirstButtonReturn:
            Task { await install(release) }
        case .alertThirdButtonReturn:
            defaults.set(release.version, forKey: Keys.skippedVersion)
        default:
            break
        }
    }

    // MARK: - Installing

    private func install(_ release: Release) async {
        status = .installing
        do {
            let app = Bundle.main.bundleURL
            guard !app.path.contains("/AppTranslocation/") else { throw UpdateError.translocated }
            guard let archive = release.archive else { throw UpdateError.noDownload }
            guard isSignedWithCertificate(app) else { throw UpdateError.unsignedCopy }

            // A scratch folder on the same volume, so the swap is a rename.
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            defer { try? FileManager.default.removeItem(at: work) }

            var request = URLRequest(url: archive)
            request.setValue("Tuck/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (download, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noDownload }
            let zip = work.appendingPathComponent("Tuck.zip")
            try FileManager.default.moveItem(at: download, to: zip)
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

            let update = work.appendingPathComponent("Tuck.app")
            guard satisfiesOwnRequirement(update) else { throw UpdateError.badSignature }
            let version = Bundle(url: update)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard version == release.version else { throw UpdateError.badSignature }

            _ = try FileManager.default.replaceItemAt(app, withItemAt: update)
            Permissions.relaunch()
        } catch {
            status = .failed(error.localizedDescription)
            let response = alert(
                title: String(localized: "Couldn't install the update"),
                message: error.localizedDescription,
                buttons: [String(localized: "Open Download Page"), String(localized: "Cancel")]
            )
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.page)
            }
        }
    }

    /// False for ad hoc builds, which can't prove a later download came from the same signer.
    private func isSignedWithCertificate(_ url: URL) -> Bool {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard
            SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any]
        else { return false }
        return !certificates.isEmpty
    }

    /// Whether the app at `url` is validly signed by whoever signed this copy.
    /// Fails for ad hoc builds, whose requirement names one exact binary.
    private func satisfiesOwnRequirement(_ url: URL) -> Bool {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard
            SecCodeCopySelf([], &running) == errSecSuccess, let running,
            SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
            SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
            SecStaticCodeCreateWithPath(url as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.noDownload)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - GitHub

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tuck/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let body: String?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(
            version: version,
            notes: payload.body ?? "",
            page: payload.html_url,
            archive: payload.assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url
        )
    }

    /// Compares dotted version numbers; "0.0.0-dev" counts as 0.0.0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Alerts

    private func showError() {
        guard case .failed(let message) = status else { return }
        let response = alert(
            title: String(localized: "Couldn't check for updates"),
            message: message,
            buttons: [String(localized: "Open Download Page"), String(localized: "Cancel")]
        )
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }

    @discardableResult
    private func alert(title: String, message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        // Tuck has no Dock icon, so bring it forward or the alert hides behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private enum Keys {
        static let lastCheck = "lastUpdateCheck"
        static let skippedVersion = "skippedUpdateVersion"
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case noDownload
    case badSignature
    case unsignedCopy
    case translocated

    var errorDescription: String? {
        switch self {
        case .badResponse: String(localized: "GitHub didn't return the latest release.")
        case .noDownload: String(localized: "The update couldn't be downloaded.")
        case .badSignature: String(localized: "The download isn't signed like this copy of Tuck, so it wasn't installed.")
        case .unsignedCopy: String(localized: "This copy of Tuck was built locally and can't update itself.")
        case .translocated: String(localized: "Move Tuck to the Applications folder first, then try again.")
        }
    }
}
