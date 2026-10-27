//
//  WritingSettingsTests.swift
//  freewriteTests
//
//  A page's own font and size in its manifest, and the size steps of the bar's "18px".
//

import Foundation
import Testing
@testable import freewrite

struct WritingSettingsTests {
    private func decode(_ json: String) throws -> WritingSettings {
        try JSONDecoder().decode(WritingSettings.self, from: Data(json.utf8))
    }

    @Test func decodesTolerantly() throws {
        #expect(try decode(#"{"font":"Arial","size":20}"#) == WritingSettings(font: "Arial", size: 20))
        #expect(try decode(#"{"size":22}"#) == WritingSettings(size: 22))
        #expect(try decode("{}").isEmpty)
        // Wrong types, blank names and silly sizes are just "use the default".
        #expect(try decode(#"{"font":7,"size":"big"}"#).isEmpty)
        #expect(try decode(#"{"font":"  ","size":4000}"#).isEmpty)
        #expect(try decode(#"{"font":"Georgia","size":-1,"colour":"red"}"#) == WritingSettings(font: "Georgia"))
    }

    @Test func resolvesAgainstDefaultsAndOverlays() {
        let page = WritingSettings(font: "Arial")
        #expect(page.resolvedFont(default: "Lato-Regular") == "Arial")
        #expect(page.resolvedSize(default: 18) == 18)
        // A template with only a size keeps the page's font.
        #expect(page.overlaid(with: WritingSettings(size: 24)) == WritingSettings(font: "Arial", size: 24))
        #expect(page.overlaid(with: WritingSettings()) == page)
    }

    @Test func sizeCyclesAndSteps() {
        #expect(WritingFont.nextSize(after: 18) == 20)
        #expect(WritingFont.nextSize(after: 26) == 16)
        #expect(WritingFont.nextSize(after: 19) == 20)
        #expect(WritingFont.nextSize(after: 40) == 16)
        #expect(WritingFont.size(18, steppedBy: 1) == 20)
        #expect(WritingFont.size(16, steppedBy: -1) == 16)
        #expect(WritingFont.size(26, steppedBy: 1) == 26)
        #expect(WritingFont.size(19, steppedBy: 1) == 20)
        #expect(WritingFont.size(19, steppedBy: -1) == 18)
    }
}

struct PageWritingStoreTests {
    private let fileManager = FileManager.default
    private let entry = "[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md"

    private func makeStore(text: String = "first draft") throws -> EntryVersionStore {
        let root = fileManager.temporaryDirectory.appendingPathComponent("freewrite-writing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EntryVersionStore(root: root)
        try text.write(to: store.entryFileURL(for: entry), atomically: true, encoding: .utf8)
        return store
    }

    @Test func plainEntryHasNoSettingsAndClearingCreatesNothing() throws {
        let store = try makeStore()
        #expect(store.writingSettings(for: entry) == nil)
        #expect(try store.setWritingSettings(nil, for: entry) == nil)
        #expect(try store.setWritingSettings(WritingSettings(), for: entry) == nil)
        #expect(!fileManager.fileExists(atPath: store.entriesURL.path))
    }

    @Test func storingCreatesAManifestWithJustTheImplicitV1() throws {
        let store = try makeStore()
        let implicit = store.manifest(for: entry)
        let saved = try #require(try store.setWritingSettings(WritingSettings(font: "Arial", size: 22), for: entry))

        #expect(saved.versions == implicit.versions)
        #expect(saved.current == "v1")
        #expect(!saved.isInteresting)
        #expect(store.writingSettings(for: entry) == WritingSettings(font: "Arial", size: 22))
        #expect(store.versions(for: entry).map(\.id) == ["v1"])
        #expect(try store.text(of: "v1", for: entry) == "first draft")

        let json = try String(contentsOf: store.manifestURL(for: entry), encoding: .utf8)
        #expect(json.contains(#""writing""#))
        #expect(json.contains(#""font" : "Arial""#))
    }

    @Test func sealingAndVoiceNotesKeepTheSettings() throws {
        let store = try makeStore()
        try store.setWritingSettings(WritingSettings(font: "Times New Roman", size: 24), for: entry)
        let sealed = try store.sealCurrent(entryFilename: entry)
        #expect(sealed.current == "v2")
        #expect(sealed.writing == WritingSettings(font: "Times New Roman", size: 24))

        let audio = store.root.appendingPathComponent("note.m4a")
        try Data("audio".utf8).write(to: audio)
        let attached = try store.attachVoiceNote(from: audio, to: entry)
        #expect(attached.manifest.writing == WritingSettings(font: "Times New Roman", size: 24))
        #expect(store.writingSettings(for: entry) == WritingSettings(font: "Times New Roman", size: 24))

        // Setting it on an entry with versions leaves them alone.
        let changed = try #require(try store.setWritingSettings(WritingSettings(size: 16), for: entry))
        #expect(changed.versions.map(\.id) == ["v1", "v2"])
        #expect(changed.versions[1].audio == attached.audioPath)
        // Clearing an existing manifest drops the field, keeps the versions.
        let cleared = try #require(try store.setWritingSettings(nil, for: entry))
        #expect(cleared.writing == nil)
        #expect(cleared.versions.count == 2)
        let json = try String(contentsOf: store.manifestURL(for: entry), encoding: .utf8)
        #expect(!json.contains("writing"))
    }

    @Test func manifestsWithoutOrWithABrokenWritingFieldStillDecode() throws {
        let store = try makeStore()
        let url = store.manifestURL(for: entry)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let versions = #"[{"id":"v1","n":1,"createdAt":"2026-02-20T08:01:04Z","source":"typed"},{"id":"v2","n":2,"createdAt":"2026-02-21T08:01:04Z","source":"typed"}]"#

        try Data(#"{"current":"v2","versions":\#(versions)}"#.utf8).write(to: url)
        #expect(store.manifest(for: entry).versions.count == 2)
        #expect(store.writingSettings(for: entry) == nil)

        try Data(#"{"current":"v2","versions":\#(versions),"writing":"huge"}"#.utf8).write(to: url)
        #expect(store.manifest(for: entry).versions.count == 2)
        #expect(store.writingSettings(for: entry) == nil)

        try Data(#"{"current":"v2","versions":\#(versions),"writing":{"size":"x","font":"Arial"}}"#.utf8).write(to: url)
        #expect(store.manifest(for: entry).current == "v2")
        #expect(store.writingSettings(for: entry) == WritingSettings(font: "Arial"))
    }

    @Test func corruptManifestIsNeverOverwritten() throws {
        let store = try makeStore()
        let url = store.manifestURL(for: entry)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{not json".utf8)
        try garbage.write(to: url)

        #expect(store.writingSettings(for: entry) == nil)
        #expect(throws: (any Error).self) { try store.setWritingSettings(WritingSettings(size: 20), for: entry) }
        #expect(throws: (any Error).self) { try store.setWritingSettings(nil, for: entry) }
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test func missingEntryThrowsAndCreatesNoFolder() throws {
        let store = try makeStore()
        try fileManager.removeItem(at: store.entryFileURL(for: entry))
        #expect(throws: EntryVersionStore.Failure.missingEntry(entry)) {
            try store.setWritingSettings(WritingSettings(size: 20), for: entry)
        }
        #expect(!fileManager.fileExists(atPath: store.entriesURL.path))
    }
}
