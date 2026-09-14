import CoreServices
import Foundation

public enum FileChangeRouting {
    /// FSEvents is an invalidation stream: inspect current state rather than treating flags as exact operations.
    public static func scope(path raw: String, flags: UInt32, root rawRoot: String, indexPath: String = "", exclusions: [String] = []) -> String? {
        let recovery = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
        if flags & recovery != 0 { return "" }
        if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { return nil }
        let path = normalized(raw), root = normalized(rawRoot), index = normalized(indexPath)
        if !index.isEmpty, path == index || path.hasPrefix(index + "/") { return nil }
        if path == root || path == "/" || root.hasPrefix(path + "/") { return "" }
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        let relative = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
        guard !LocalFiles.excluded(relative, patterns: exclusions) else { return nil }
        return (relative as NSString).deletingLastPathComponent
    }

    private static func normalized(_ raw: String) -> String {
        var path = raw
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        if path == "/private/tmp" || path.hasPrefix("/private/tmp/") || path == "/private/var" || path.hasPrefix("/private/var/") { path = String(path.dropFirst("/private".count)) }
        return path
    }
}
