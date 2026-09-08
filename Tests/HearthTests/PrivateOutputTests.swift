// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import Testing
@testable import Hearth

struct PrivateOutputTests {
    @Test func privateExportPreservesSharedFolderPermissions() throws {
        let directory = TestIsolation.path("export")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let output = directory.appendingPathComponent("Caddyfile.hearth")
        #expect(SecureFile.writePrivateOutput(Data("fixture-token".utf8), to: output))
        #expect(try Data(contentsOf: output) == Data("fixture-token".utf8))
        #expect(try fm.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o755)
        #expect(try fm.contentsOfDirectory(atPath: directory.path) == ["Caddyfile.hearth"])
    }

    @Test func privateExportRemovesInheritedACLButPreservesTheFolderACL() throws {
        let directory = TestIsolation.path("export-acl")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit", directory.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        func hasACL(_ url: URL) throws -> Bool {
            guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
                #expect(errno == ENOENT)
                #expect(fm.fileExists(atPath: url.path))
                return false // macOS reports ENOENT when the extended ACL is absent.
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
        }
        let inherited = directory.appendingPathComponent("ordinary-file")
        try Data("fixture".utf8).write(to: inherited)
        #expect(try hasACL(inherited))
        let output = directory.appendingPathComponent("Caddyfile.hearth")
        #expect(SecureFile.writePrivateOutput(Data("fixture-token".utf8), to: output))
        #expect(try !hasACL(output))
        #expect(try hasACL(directory))
    }

    @Test func exportReplacesSymlinkWithoutWritingItsTarget() throws {
        let directory = TestIsolation.path("export-link")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original")
        try Data("unchanged".utf8).write(to: original)
        let output = directory.appendingPathComponent("Caddyfile.hearth")
        try fm.createSymbolicLink(at: output, withDestinationURL: original)
        #expect(SecureFile.writePrivateOutput(Data("fixture-token".utf8), to: output))
        #expect(try String(contentsOf: original, encoding: .utf8) == "unchanged")
        #expect(try fm.attributesOfItem(atPath: output.path)[.type] as? FileAttributeType == .typeRegular)
    }

    @Test func failedExportRemovesPrivateStagingFile() throws {
        let directory = TestIsolation.path("export-failure")
        let fm = FileManager.default
        let output = directory.appendingPathComponent("Caddyfile.hearth")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        #expect(!SecureFile.writePrivateOutput(Data("fixture-token".utf8), to: output))
        #expect(try fm.contentsOfDirectory(atPath: directory.path) == ["Caddyfile.hearth"])
    }
}
