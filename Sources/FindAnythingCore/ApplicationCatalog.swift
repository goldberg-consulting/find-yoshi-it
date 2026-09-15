import AppKit
import Darwin
import Foundation

/// A launchable application discovered independently of document indexing and Spotlight.
public struct ApplicationRecord: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleIdentifier: String?

    /// Describe an application at its user-visible bundle path.
    public init(path: String, name: String, bundleIdentifier: String? = nil) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Keeps a small local catalog of installed applications for immediate launcher searches.
public actor ApplicationCatalog {
    public static var defaultRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        ]
    }

    private let roots: [URL]
    private let additionalRoots: @Sendable () async -> [URL]
    private let registryLookup: (@Sendable (String) -> URL?)?
    private var resolvedApplications: [String: ApplicationRecord] = [:]
    private var attemptedNames: [String: ContinuousClock.Instant] = [:]
    private var applications: [ApplicationRecord] = []
    private var preferredPaths = Set<String>()
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: ContinuousClock.Instant?

    /// Discover only the supplied application directories or bundles, using standard macOS locations by default.
    public init(roots: [URL]? = nil, registryLookup: (@Sendable (String) -> URL?)? = nil, additionalRoots: (@Sendable () async -> [URL])? = nil) {
        self.roots = roots ?? ApplicationCatalog.defaultRoots
        self.additionalRoots = additionalRoots ?? (roots == nil ? { @Sendable in
            await MainActor.run {
                NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
            }
        } : { @Sendable in [] })
        self.registryLookup = registryLookup ?? (roots == nil ? { @Sendable name in
            // LaunchServices has no modern name-based replacement. Bundle-ID lookup alone
            // cannot resolve a typed app name or discover apps outside standard folders.
            NSWorkspace.shared.fullPath(forApplication: name).map { URL(fileURLWithPath: $0) }
        } : nil)
    }

    /// Refresh in the background; concurrent requests coalesce and ordinary refreshes cache for five minutes.
    public func refresh(force: Bool = false) async {
        if let task = refreshTask {
            await task.value
            if force { await refresh(force: true) }
            return
        }
        if !force, let lastRefresh, lastRefresh.duration(to: .now) < .seconds(300) { return }
        let roots = roots
        let task = Task {
            let extraRoots = await additionalRoots()
            let discovered = await ApplicationDiscovery.discover(roots + extraRoots)
            preferredPaths = Set(extraRoots.map(\.path))
            applications = discovered
            lastRefresh = .now
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    /// Rank cached application names by exact words, prefixes, abbreviations, and close subsequences.
    public func search(_ query: String, limit: Int = 8) async -> [ApplicationRecord] {
        guard limit > 0 else { return [] }
        let rawQuery = String(query.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
        let query = ApplicationName.normalized(rawQuery)
        guard !query.isEmpty else { return [] }
        if let registryLookup, query.count >= 2,
           attemptedNames[query].map({ $0.duration(to: .now) >= .seconds(30) }) ?? true {
            attemptedNames[query] = .now
            if attemptedNames.count > 256 { attemptedNames = [query: .now] }
            if let record = await ApplicationDiscovery.resolve(rawQuery, lookup: registryLookup) {
                resolvedApplications[record.path] = record
            }
        }
        let extras = resolvedApplications.values.filter { FileManager.default.fileExists(atPath: $0.path) && !applications.contains($0) }
        var unique: [String: ApplicationRecord] = [:]
        for application in applications + extras {
            let key = application.bundleIdentifier ?? application.path
            if let old = unique[key] {
                if preferredPaths.contains(application.path) && !preferredPaths.contains(old.path) { unique[key] = application }
            } else { unique[key] = application }
        }
        return unique.values.compactMap { application -> (ApplicationRecord, Int)? in
            let displayScore = ApplicationName.score(query, name: application.name)
            let filename = URL(fileURLWithPath: application.path).deletingPathExtension().lastPathComponent
            let filenameScore = ApplicationName.score(query, name: filename).map { $0 - 10 }
            guard let score = [displayScore, filenameScore].compactMap({ $0 }).max() else { return nil }
            return (application, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let order = $0.0.name.localizedCaseInsensitiveCompare($1.0.name)
            return order == .orderedSame ? $0.0.path < $1.0.path : order == .orderedAscending
        }.prefix(min(limit, 50)).map(\.0)
    }
}

private enum ApplicationDiscovery {
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.findanything.application-catalog"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private static let packageExtensions: Set<String> = ["framework", "bundle", "plugin", "appex", "xpc", "kext", "prefpane", "qlgenerator", "mdimporter"]

    static func discover(_ roots: [URL]) async -> [ApplicationRecord] {
        await withCheckedContinuation { continuation in
            workers.addOperation { continuation.resume(returning: read(roots)) }
        }
    }

    static func resolve(_ name: String, lookup: @escaping @Sendable (String) -> URL?) async -> ApplicationRecord? {
        await withCheckedContinuation { continuation in
            workers.addOperation {
                guard let url = lookup(name), url.isFileURL, url.pathExtension.lowercased() == "app",
                      let target = applicationTarget(url) else { continuation.resume(returning: nil); return }
                continuation.resume(returning: record(visibleURL: url, target: target))
            }
        }
    }

    private static func read(_ roots: [URL]) -> [ApplicationRecord] {
        var applications: [ApplicationRecord] = []
        var canonicalApplications = Set<String>()
        var directories = Set<String>()
        var inspectedEntries = 0
        for root in roots where root.isFileURL && root.path != "/" {
            if root.pathExtension.lowercased() == "app" {
                if let canonical = applicationTarget(root),
                   canonicalApplications.insert(canonical.path).inserted,
                   let application = record(visibleURL: root, target: canonical) {
                    applications.append(application)
                }
                continue
            }
            var pending = [(root, 0)]
            while let (directory, depth) = pending.popLast(), inspectedEntries < 20_000 {
                let path = directory.path
                guard directories.insert(path).inserted, kind(path) == S_IFDIR,
                      let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
                for name in names.sorted() where !name.hasPrefix(".") {
                    inspectedEntries += 1
                    guard inspectedEntries <= 20_000 else { break }
                    let url = directory.appendingPathComponent(name, isDirectory: true)
                    let ext = url.pathExtension.lowercased()
                    let type = kind(url.path)
                    if ext == "app" {
                        guard let canonical = applicationTarget(url),
                              canonicalApplications.insert(canonical.path).inserted,
                              let application = record(visibleURL: url, target: canonical) else { continue }
                        applications.append(application)
                    } else if type == S_IFDIR, depth < 5, !packageExtensions.contains(ext) {
                        // Ordinary symlink directories are never followed, and application bundles are leaves.
                        pending.append((url, depth + 1))
                    }
                }
            }
        }
        return applications
    }

    private static func record(visibleURL: URL, target: URL) -> ApplicationRecord? {
        let infoURL = target.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        var info: [String: Any] = [:]
        var stamp = stat()
        if lstat(infoURL.path, &stamp) == 0, stamp.st_mode & S_IFMT == S_IFREG,
           stamp.st_size <= 1_048_576,
           let data = try? Data(contentsOf: infoURL),
           let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            info = dictionary
        }
        let bundleIdentifier = usableName(info["CFBundleIdentifier"])
        // Some user-facing .app bundles (including Passwords) use XPC!.
        // Discovery already treats app bundles as leaves and skips .xpc helpers.
        if let type = info["CFBundlePackageType"] as? String,
           !["APPL", "XPC!"].contains(type), !(type == "FNDR" && bundleIdentifier == "com.apple.finder") { return nil }
        if let background = info["LSBackgroundOnly"] as? NSNumber, background.boolValue { return nil }
        if let background = info["LSBackgroundOnly"] as? String, ["1", "true", "yes"].contains(background.lowercased()) { return nil }
        let name = usableName(info["CFBundleDisplayName"]) ?? usableName(info["CFBundleName"]) ?? visibleURL.deletingPathExtension().lastPathComponent
        return ApplicationRecord(path: visibleURL.path, name: name, bundleIdentifier: bundleIdentifier)
    }

    private static func usableName(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let value = raw.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return String(value.prefix(256))
    }

    private static func applicationTarget(_ url: URL) -> URL? {
        var path = url.path
        var seen = Set<String>()
        for _ in 0..<8 {
            guard seen.insert(path).inserted else { return nil }
            switch kind(path) {
            case S_IFDIR: return URL(fileURLWithPath: path, isDirectory: true)
            case S_IFLNK:
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
                let raw = destination.hasPrefix("/") ? destination : (path as NSString).deletingLastPathComponent + "/" + destination
                path = lexicalPath(raw)
            default: return nil
            }
        }
        return nil
    }

    private static func kind(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func lexicalPath(_ path: String) -> String {
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        return "/" + components.joined(separator: "/")
    }
}

private enum ApplicationName {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func score(_ query: String, name: String) -> Int? {
        let folded = normalized(name)
        guard !folded.isEmpty else { return nil }
        let compact = folded.replacingOccurrences(of: " ", with: "")
        let needle = query.replacingOccurrences(of: " ", with: "")
        if folded == query { return 1_000 }
        if compact == needle { return 980 }
        let camelSeparated = name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        let tokens = normalized(camelSeparated).split(separator: " ").map(String.init)
        let words = query.split(separator: " ").map(String.init)
        if words.count == 1, tokens.contains(query) { return 920 }
        if folded.hasPrefix(query) { return 900 - min(folded.count - query.count, 30) }
        if words.count > 1, orderedPrefixes(words, tokens: tokens) { return 860 }
        if needle.count >= 2, tokens.contains(where: { $0.hasPrefix(needle) }) { return 820 }
        let acronym = tokens.compactMap(\.first).map(String.init).joined()
        if tokens.count > 1, needle.count >= 2, acronym == needle { return 850 }
        if tokens.count > 1, needle.count >= 2, abbreviation(needle, tokens: Array(tokens.prefix(16))) { return 800 + min(needle.count, 30) }
        guard needle.count >= 3, compact.first == needle.first else { return nil }
        let target = Array(compact)
        var cursor = 0
        for character in needle {
            guard let next = target[cursor...].firstIndex(of: character) else { return nil }
            cursor = next + 1
        }
        let gaps = cursor - needle.count
        guard gaps <= 3, Double(needle.count) / Double(cursor) >= 0.65 else { return nil }
        return 500 - gaps * 20
    }

    private static func orderedPrefixes(_ words: [String], tokens: [String]) -> Bool {
        var cursor = 0
        for word in words {
            guard let index = tokens[cursor...].firstIndex(where: { $0.hasPrefix(word) }) else { return false }
            cursor = index + 1
        }
        return true
    }

    private static func abbreviation(_ query: String, tokens: [String]) -> Bool {
        let query = Array(query)
        var visited = Set<Int>()
        func matches(_ token: Int, _ position: Int) -> Bool {
            if position == query.count { return token >= 2 }
            guard token < tokens.count else { return false }
            let key = token * 129 + position
            guard visited.insert(key).inserted else { return false }
            let letters = Array(tokens[token])
            for length in 1...min(letters.count, query.count - position) {
                guard letters[length - 1] == query[position + length - 1] else { break }
                if matches(token + 1, position + length) { return true }
            }
            return false
        }
        return matches(0, 0)
    }
}
