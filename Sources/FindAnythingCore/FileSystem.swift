import Foundation
import CryptoKit
import Darwin

struct FileStamp: Equatable, Sendable {
    var size: Int64
    var modified: Date
    var changed: Date
    static func read(_ url: URL) throws -> FileStamp {
        var info = stat()
        guard lstat(url.path,&info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw DatabaseError(message:"The source is no longer a regular file.") }
        return FileStamp(size:Int64(info.st_size), modified:Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec)+Double(info.st_mtimespec.tv_nsec)/1e9), changed:Date(timeIntervalSince1970:Double(info.st_ctimespec.tv_sec)+Double(info.st_ctimespec.tv_nsec)/1e9))
    }
}

struct FolderIdentity: Sendable {
    var identity: String
    var kind: SourceKind
    static func read(_ url: URL) throws -> FolderIdentity {
        let values = try url.resourceValues(forKeys:[.isDirectoryKey,.volumeUUIDStringKey,.volumeIsLocalKey,.volumeIsInternalKey,.volumeURLKey])
        guard values.isDirectory == true else { throw DatabaseError(message:"Choose an available folder or mounted share.") }
        var info = statfs()
        guard statfs(url.path,&info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        let from = withUnsafePointer(to:&info.f_mntfromname) { $0.withMemoryRebound(to:CChar.self,capacity:1024) { String(cString:$0) } }
        let mount = withUnsafePointer(to:&info.f_mntonname) { $0.withMemoryRebound(to:CChar.self,capacity:1024) { String(cString:$0) } }
        let type = withUnsafePointer(to:&info.f_fstypename) { $0.withMemoryRebound(to:CChar.self,capacity:16) { String(cString:$0) } }
        let network = values.volumeIsLocal == false || ["smbfs","nfs","afpfs","webdav"].contains(type)
        let kind: SourceKind = network ? .network : (values.volumeIsInternal == false ? .external : .local)
        let relative = url.path.hasPrefix(mount) ? String(url.path.dropFirst(mount.count)) : url.path
        let volume = network ? from : (values.volumeUUIDString ?? from)
        return FolderIdentity(identity:"\(type)|\(volume)|\(relative)",kind:kind)
    }
}

struct DirectoryEntry: Sendable {
    var url: URL
    var isDirectory: Bool
    var isRegular: Bool
    var isSymlink: Bool
}

enum LocalFiles {
    static let maximumFileBytes: Int64 = 128 * 1024 * 1024
    static func networkRemounts(identity: String) -> [URL] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts,MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        defer { free(mounts) }
        var results: [URL] = []
        for index in 0..<Int(count) {
            var info = mounts[index]
            let from = withUnsafePointer(to:&info.f_mntfromname) { $0.withMemoryRebound(to:CChar.self,capacity:1024) { String(cString:$0) } }
            let type = withUnsafePointer(to:&info.f_fstypename) { $0.withMemoryRebound(to:CChar.self,capacity:16) { String(cString:$0) } }
            let prefix = type+"|"+from+"|"
            guard identity.hasPrefix(prefix) else { continue }
            let mount = withUnsafePointer(to:&info.f_mntonname) { $0.withMemoryRebound(to:CChar.self,capacity:1024) { String(cString:$0) } }
            let relative = String(identity.dropFirst(prefix.count)).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            results.append(URL(fileURLWithPath:mount,isDirectory:true).appendingPathComponent(relative,isDirectory:true))
        }
        return results
    }
    static func list(_ directory: URL) throws -> [DirectoryEntry] {
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw DatabaseError(message:"A folder was redirected through a symbolic link. It was not scanned.") }
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(keys)).map {
            let values = try $0.resourceValues(forKeys:keys)
            return DirectoryEntry(url:$0,isDirectory:values.isDirectory == true,isRegular:values.isRegularFile == true,isSymlink:values.isSymbolicLink == true)
        }
    }

    static func excluded(_ relative: String, patterns: [String]) -> Bool {
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            guard !pattern.isEmpty else { continue }
            if pattern.contains("/") {
                if relative == pattern || relative.hasPrefix(pattern+"/") || fnmatch(pattern,relative,0) == 0 { return true }
            } else if relative.split(separator:"/").contains(where:{ fnmatch(pattern,String($0),0) == 0 }) { return true }
        }
        return false
    }

    static func permissionError(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return value.code == Int(EACCES) || value.code == Int(EPERM) }
        if value.domain == NSCocoaErrorDomain { return [NSFileReadNoPermissionError,NSFileWriteNoPermissionError].contains(value.code) }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return permissionError(underlying) }
        return false
    }

    /// Snapshot only selected, bounded files. Hash and extractor observe the same bytes.
    static func snapshot(_ url: URL, root: URL) throws -> (url: URL, hash: String, stamp: FileStamp) {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw POSIXError(.EACCES) }
        let before = try FileStamp.read(url)
        guard before.size <= maximumFileBytes else { throw DatabaseError(message:"Content exceeds the current 128 MiB per-file limit. Filename and metadata remain searchable.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FindAnything-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let snapshot = folder.appendingPathComponent(url.lastPathComponent)
        FileManager.default.createFile(atPath:snapshot.path,contents:nil,attributes:[.posixPermissions:0o600])
        do {
            let reader = try openWithinRoot(url,root:root)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo:snapshot)
            defer { try? writer.close() }
            var hash = SHA256()
            var count: Int64 = 0
            while let data = try reader.read(upToCount:1024*1024), !data.isEmpty {
                try Task.checkCancellation()
                count += Int64(data.count)
                guard count <= maximumFileBytes else { throw DatabaseError(message:"File grew beyond the content size limit during indexing.") }
                hash.update(data:data)
                try writer.write(contentsOf:data)
            }
            guard before == (try FileStamp.read(url)), count == before.size else { throw DatabaseError(message:"File changed while it was being read. It will be retried.") }
            return (snapshot,hash.finalize().map { String(format:"%02x",$0) }.joined(),before)
        } catch {
            try? FileManager.default.removeItem(at:folder)
            throw error
        }
    }

    /// Traverse via directory descriptors so a replaced child symlink cannot escape the selected root.
    private static func openWithinRoot(_ url: URL, root: URL) throws -> FileHandle {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath == "/" ? "/":rootPath+"/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw POSIXError(.EACCES) }
        let components = String(url.standardizedFileURL.path.dropFirst(prefix.count)).split(separator:"/").map(String.init)
        guard !components.isEmpty, !components.contains("..") else { throw POSIXError(.EACCES) }
        var directoryFD = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { close(directoryFD) }
        for component in components.dropLast() {
            let next = openat(directoryFD,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            close(directoryFD); directoryFD = next
        }
        let descriptor = openat(directoryFD,components.last!,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(descriptor); throw POSIXError(.EACCES) }
        return FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
    }
}
