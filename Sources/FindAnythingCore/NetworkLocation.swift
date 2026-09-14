import Darwin
import Foundation
import CryptoKit

/// A validated SMB server or share address without embedded credentials.
public struct SMBAddress: Sendable, Equatable {
    public let url: URL
    public let host: String

    public var displayName: String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    /// Accept a hostname, IP address, or SMB URL. Authentication belongs to macOS.
    public init(_ text: String) throws {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains("\\"),
              input.rangeOfCharacter(from: .controlCharacters) == nil,
              Self.hasValidEscapes(input) else { throw SMBAddressError.invalidAddress }

        let candidate: String
        if let separator = input.range(of: "://") {
            guard input[..<separator.lowerBound].lowercased() == "smb" else { throw SMBAddressError.unsupportedScheme }
            candidate = input
        } else {
            guard !input.hasPrefix("/"), !input.lowercased().hasPrefix("smb:") else { throw SMBAddressError.invalidAddress }
            let parts = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let authority = String(parts[0])
            if authority.filter({ $0 == ":" }).count >= 2 && !authority.hasPrefix("[") {
                candidate = "smb://[\(authority)]" + (parts.count == 2 ? "/\(parts[1])" : "")
            } else {
                candidate = "smb://" + input
            }
        }
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "smb" else { throw SMBAddressError.invalidAddress }
        guard components.user == nil, components.password == nil else { throw SMBAddressError.credentialsNotAllowed }
        guard components.query == nil, components.fragment == nil,
              let parsedHost = components.host, !parsedHost.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw SMBAddressError.invalidAddress }

        let host = parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]")
            ? String(parsedHost.dropFirst().dropLast()) : parsedHost
        guard Self.validHost(host),
              components.path.rangeOfCharacter(from: .controlCharacters) == nil,
              !components.path.contains("\\"),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw SMBAddressError.invalidAddress }
        components.scheme = "smb"
        if !host.contains(":") { components.host = host.lowercased() }
        guard let url = components.url else { throw SMBAddressError.invalidAddress }
        self.url = url
        self.host = host.contains(":") ? host : host.lowercased()
    }

    private static func hasValidEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let hexadecimal: (UInt8) -> Bool = { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        for position in bytes.indices where bytes[position] == 37 {
            guard position + 2 < bytes.count,
                  hexadecimal(bytes[position + 1]), hexadecimal(bytes[position + 2]) else { return false }
        }
        return true
    }

    private static func validHost(_ value: String) -> Bool {
        if value.contains(":") {
            let parts = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
                guard !parts[1].isEmpty, parts[1].unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
            }
            var address = in6_addr()
            return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        guard value.utf8.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if value.allSatisfy({ $0.isNumber || $0 == "." }) {
            var address = in_addr()
            return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
        }
        let name = value.hasSuffix(".") ? String(value.dropLast()) : value
        return !name.isEmpty && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
        }
    }
}

/// Validation errors never include user input, which may contain accidental credentials.
public enum SMBAddressError: LocalizedError, Sendable, Equatable {
    case invalidAddress
    case unsupportedScheme
    case credentialsNotAllowed

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a server name, IP address, or address such as smb://server/share."
        case .unsupportedScheme: return "Use an SMB address beginning with smb://."
        case .credentialsNotAllowed: return "Leave usernames and passwords out of the address. macOS will ask you to sign in."
        }
    }
}

/// An SMB share already present in the kernel's cached mount table.
public struct MountedNetworkShare: Identifiable, Sendable, Hashable {
    public var id: String { path + "|" + identityToken }
    public let path: String
    public let name: String
    public let server: String
    public let identityToken: String

    /// Describe a mount without accessing its files or resolving symbolic links.
    public init(path: String, name: String, server: String, identityToken: String? = nil) {
        self.path = Self.lexicalPath(path)
        self.name = name
        self.server = server
        self.identityToken = identityToken ?? Self.token("smbfs|//\(server)/\(name)")
    }

    /// Read cached SMB mounts without contacting servers or querying volume resources.
    public static func mounted() -> [MountedNetworkShare] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        defer { free(buffer) }
        var shares: [MountedNetworkShare] = []
        for position in 0..<Int(count) {
            var entry = buffer[position]
            let type = kernelString(&entry.f_fstypename)
            guard type == "smbfs" else { continue }
            let from = kernelString(&entry.f_mntfromname)
            let path = kernelString(&entry.f_mntonname)
            if let share = parseMount(fileSystem: type, mountedFrom: from, mountedOn: path) { shares.append(share) }
        }
        return Array(Set(shares)).sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
        }
    }

    static func parseMount(fileSystem: String, mountedFrom: String, mountedOn: String) -> MountedNetworkShare? {
        guard fileSystem == "smbfs", mountedOn.hasPrefix("/"),
              mountedOn.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let source: String
        if mountedFrom.hasPrefix("//") {
            source = String(mountedFrom.dropFirst(2))
        } else if mountedFrom.lowercased().hasPrefix("smb://") {
            source = String(mountedFrom.dropFirst(6))
        } else { return nil }
        guard let slash = source.firstIndex(of: "/") else { return nil }
        let authority = source[..<slash]
        // Kernel mount strings may contain DOMAIN;user or user:password. Never expose them.
        let server = authority.lastIndex(of: "@").map { String(authority[authority.index(after: $0)...]) } ?? String(authority)
        let sharePath = String(source[slash...])
        guard let base = try? SMBAddress("smb://" + server),
              var components = URLComponents(url: base.url, resolvingAgainstBaseURL: false) else { return nil }
        // A mount-table share name is a path, never a query or fragment.
        components.path = sharePath.removingPercentEncoding ?? sharePath
        guard let value = components.url?.absoluteString,
              let address = try? SMBAddress(value),
              let name = address.url.path.split(separator: "/").first, !name.isEmpty else { return nil }
        return MountedNetworkShare(path: mountedOn, name: String(name), server: address.host, identityToken: token(fileSystem + "|" + mountedFrom))
    }

    private static func token(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func lexicalPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func kernelString<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}
