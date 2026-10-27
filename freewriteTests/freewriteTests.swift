//
//  freewriteTests.swift
//  freewriteTests
//
//  Created by thorfinn on 2/14/25.
//

import Foundation
import Testing
@testable import freewrite

struct StorageTransferTests {
    private let fileManager = FileManager.default
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"
    private let video = "Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].mov"
    private let thumbnail = "Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]/thumbnail.jpg"

    private func makeFolder() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("freewrite-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A folder with one text entry, one video entry and some files Freewrite doesn't own.
    private func makeSource() throws -> URL {
        let root = try makeFolder()
        try write("\n\nhello", entry, in: root)
        try write("Video Entry", "[AAAAAAAA-75FC-415C-ABB9-C76644B037B2]-[2026-02-21-08-01-04].md", in: root)
        try write("movie", video, in: root)
        try write("jpg", thumbnail, in: root)
        try write("not ours", "notes.txt", in: root)
        try write("not ours", "README.md", in: root)
        try write("not ours", "holiday.mov", in: root)
        try write("not ours", "[not-a-uuid]-[2026-02-20-08-01-04].md", in: root)
        try write("not ours", "Other/file.md", in: root)
        try write("hidden", ".DS_Store", in: root)
        return root
    }

    @Test func listsOnlyFreewriteFiles() throws {
        let root = try makeSource()
        #expect(StorageTransfer.items(in: root) == [
            "Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].mov",
            "Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]/thumbnail.jpg",
            entry,
            "[AAAAAAAA-75FC-415C-ABB9-C76644B037B2]-[2026-02-21-08-01-04].md",
        ].sorted())
    }

    @Test func copyKeepsOriginals() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        let report = StorageTransfer.transfer(from: source, to: destination, mode: .copy)

        #expect(report.succeeded)
        #expect(report.copied.count == 4)
        #expect(report.skipped.isEmpty)
        #expect(read(entry, in: destination) == "\n\nhello")
        #expect(read(video, in: destination) == "movie")
        #expect(read(entry, in: source) == "\n\nhello")
        #expect(read(video, in: source) == "movie")
        #expect(read("notes.txt", in: destination) == nil)
        // No temporary files left behind.
        let leftovers = try fileManager.subpathsOfDirectory(atPath: destination.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func moveRemovesOriginalsButNotForeignFiles() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        let report = StorageTransfer.transfer(from: source, to: destination, mode: .move)

        #expect(report.succeeded)
        #expect(report.notRemoved.isEmpty)
        #expect(read(entry, in: destination) == "\n\nhello")
        #expect(read(thumbnail, in: destination) == "jpg")
        #expect(StorageTransfer.items(in: source).isEmpty)
        #expect(!fileManager.fileExists(atPath: source.appendingPathComponent("Videos").path))
        #expect(read("notes.txt", in: source) == "not ours")
        #expect(read("Other/file.md", in: source) == "not ours")
        #expect(read("README.md", in: source) == "not ours")
        #expect(read("holiday.mov", in: source) == "not ours")
        #expect(read("README.md", in: destination) == nil)
        #expect(read("holiday.mov", in: destination) == nil)
    }

    @Test func recognizesEntryFilenames() {
        #expect(StorageTransfer.isEntryFilename(entry))
        #expect(StorageTransfer.isEntryFilename("[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].mov"))
        #expect(!StorageTransfer.isEntryFilename("README.md"))
        #expect(!StorageTransfer.isEntryFilename("holiday.mov"))
        #expect(!StorageTransfer.isEntryFilename("[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20].md"))
        #expect(!StorageTransfer.isEntryFilename("[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].txt"))
        let parsed = StorageTransfer.parseEntryFilename(entry)
        #expect(parsed?.uuid == UUID(uuidString: "6910BBDE-75FC-415C-ABB9-C76644B037B2"))
        #expect(StorageTransfer.parseEntryFilename(entry, extension: "mov") == nil)
    }

    @Test func legacyTopLevelVideosAreTransferred() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        let legacy = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].mov"
        try write("old movie", legacy, in: source)
        #expect(StorageTransfer.items(in: source).contains(legacy))

        let report = StorageTransfer.transfer(from: source, to: destination, mode: .move)
        #expect(report.succeeded)
        #expect(read(legacy, in: destination) == "old movie")
        #expect(read(legacy, in: source) == nil)
    }

    @Test func moveKeepsFoldersWithFilesItDidNotCopy() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        let entryFolder = "Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]"
        // Hidden files are never copied, so their folders must survive the move.
        try write("hidden", entryFolder + "/.notes", in: source)
        try write("finder", entryFolder + "/.DS_Store", in: source)
        try write("finder", "Videos/Empty/.DS_Store", in: source)

        let report = StorageTransfer.transfer(from: source, to: destination, mode: .move)

        #expect(report.succeeded)
        #expect(StorageTransfer.items(in: source).isEmpty)
        #expect(read(entryFolder + "/.notes", in: source) == "hidden")
        // A folder holding only .DS_Store is still empty.
        #expect(!fileManager.fileExists(atPath: source.appendingPathComponent("Videos/Empty").path))
    }

    @Test func entriesDeletedDuringTransferDoNotComeBack() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        let entryFolder = "Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]"
        let first = StorageTransfer.copy(from: source, to: destination)

        // The text entry and the video entry are deleted while the first pass runs.
        try fileManager.removeItem(at: source.appendingPathComponent(entry))
        try fileManager.removeItem(at: source.appendingPathComponent(entryFolder))

        var report = first
        report.merge(StorageTransfer.copy(from: source, to: destination, alreadyCopied: Set(first.copied)))
        report = StorageTransfer.dropVanished(from: report, source: source, destination: destination)

        #expect(report.succeeded)
        #expect(report.copied == ["[AAAAAAAA-75FC-415C-ABB9-C76644B037B2]-[2026-02-21-08-01-04].md"])
        #expect(read(entry, in: destination) == nil)
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent(entryFolder).path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("Videos").path))

        let moved = StorageTransfer.removeOriginals(of: report, in: source)
        #expect(moved.notRemoved.isEmpty)
        #expect(StorageTransfer.items(in: source).isEmpty)
    }

    @Test func neverOverwritesExistingFiles() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        try write("already here", entry, in: destination)
        try write("other movie", video, in: destination)

        let report = StorageTransfer.transfer(from: source, to: destination, mode: .move)

        #expect(report.succeeded)
        #expect(Set(report.skipped) == [entry, video])
        #expect(report.copied.count == 2)
        #expect(read(entry, in: destination) == "already here")
        #expect(read(video, in: destination) == "other movie")
        // Skipped originals stay in the old folder; the rest were moved.
        #expect(read(entry, in: source) == "\n\nhello")
        #expect(read(video, in: source) == "movie")
        #expect(read(thumbnail, in: source) == nil)
    }

    @Test func failedCopyDeletesNothing() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        // A file where the Videos folder should be makes every video copy fail.
        try write("blocker", "Videos", in: destination)

        let report = StorageTransfer.transfer(from: source, to: destination, mode: .move)

        #expect(!report.succeeded)
        #expect(Set(report.failed.keys) == [video, thumbnail])
        #expect(StorageTransfer.items(in: source).count == 4)
        #expect(read(entry, in: source) == "\n\nhello")
    }

    @Test func secondPassPicksUpChangesAndNewFiles() throws {
        let source = try makeSource()
        let destination = try makeFolder()
        let first = StorageTransfer.copy(from: source, to: destination)

        // Writes that land while the first pass runs.
        try write("\n\nhello again", entry, in: source)
        let newEntry = "[BBBBBBBB-75FC-415C-ABB9-C76644B037B2]-[2026-02-22-08-01-04].md"
        try write("new", newEntry, in: source)

        var report = first
        report.merge(StorageTransfer.copy(from: source, to: destination, alreadyCopied: Set(first.copied)))

        #expect(report.succeeded)
        #expect(report.skipped.isEmpty)
        #expect(report.copied.count == 5)
        #expect(read(entry, in: destination) == "\n\nhello again")
        #expect(read(newEntry, in: destination) == "new")

        let moved = StorageTransfer.removeOriginals(of: report, in: source)
        #expect(moved.notRemoved.isEmpty)
        #expect(StorageTransfer.items(in: source).isEmpty)
    }

    @Test func detectsOverlappingFolders() throws {
        let root = try makeFolder()
        #expect(StorageTransfer.overlaps(root, root.appendingPathComponent("Videos/x")))
        #expect(StorageTransfer.overlaps(root.appendingPathComponent("Videos/x"), root))
        #expect(!StorageTransfer.overlaps(root, root.appendingPathComponent("Sub")))
        #expect(!StorageTransfer.overlaps(root.appendingPathComponent("A"), root.appendingPathComponent("B")))
    }
}
