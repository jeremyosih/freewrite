//
//  Reviews.swift
//  freewrite
//
//  The note tools behind agents: reading an entry's versions, diffing them, and listing,
//  adding and resolving annotations (annotations.json). Pure: no model, no network.
//  AgentTools.swift serves them to connected agents over MCP.
//

import Foundation

// MARK: - Review runs

/// Everything a tool needs to know about the run it belongs to. Stored as a conversation
/// document so a run resumed after a crash still knows its entry and reviewer.
struct ReviewRunContext: Codable, Equatable, Sendable {
    var entryFilename: String
    var entryId: String
    var versionId: String
    var reviewerId: String
    var reviewerName: String
    var runId: String
    var scope: ReviewScope
    var summary: String?
    /// Kinds the reviewer may use (nil: all, for runs stored before kinds existed).
    var kinds: [AnnotationKind]? = nil
    /// Kind used when a note doesn't name one.
    var defaultKind: AnnotationKind? = nil
}

/// How much of an entry a run reads. Agents always review one version; `all` is kept so runs
/// stored by older builds still decode.
enum ReviewScope: String, Codable, Sendable {
    /// Only the version being reviewed (it may still look at others).
    case latest
    /// Every version, to comment on how the writing changed.
    case all
}

// MARK: - Tools (pure)

/// A tool's failure, shown to the model as an error result.
struct ReviewToolFailure: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The logic behind the reviewer tools, over the files of one run. No model involved, so it's
/// unit-tested directly; the agent server (AgentTools.swift) serves them to connected agents.
struct ReviewToolbox {
    let versionStore: EntryVersionStore
    var run: ReviewRunContext
    var now: () -> Date = Date.init

    /// Longest slice `read_version` returns at once (UTF-16 units).
    static let readLimit = 20_000

    var annotations: AnnotationStore { AnnotationStore(versionStore: versionStore) }

    /// The kinds this run's reviewer may use, in canonical order.
    var allowedKinds: [AnnotationKind] { AnnotationKind.normalized(run.kinds ?? AnnotationKind.allCases) }

    var defaultKind: AnnotationKind {
        let preferred = run.defaultKind ?? .insight
        return allowedKinds.contains(preferred) ? preferred : (allowedKinds.first ?? .insight)
    }

    /// The kind a tool call asked for, if it names one this reviewer may use. Otherwise nil and a
    /// line telling the model what happened (an empty word is not a mistake: no line).
    func allowedKind(_ raw: String?) -> (kind: AnnotationKind?, problem: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
        let allowed = allowedKinds.map(\.rawValue).joined(separator: ", ")
        guard let kind = AnnotationKind.parse(raw) else {
            return (nil, "\"\(raw)\" isn't a kind (use one of: \(allowed))")
        }
        guard allowedKinds.contains(kind) else {
            return (nil, "you can't leave \(kind.rawValue) notes (use one of: \(allowed))")
        }
        return (kind, nil)
    }

    private var manifest: EntryManifest { versionStore.manifest(for: run.entryFilename) }

    private func text(of versionId: String) throws -> String {
        guard manifest.version(versionId) != nil else {
            throw ReviewToolFailure("No version \(versionId). Call list_versions to see the ids.")
        }
        do {
            return try versionStore.text(of: versionId, for: run.entryFilename)
        } catch {
            throw ReviewToolFailure("Couldn't read \(versionId): \(error.localizedDescription)")
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    func listVersions() throws -> String {
        let manifest = manifest
        let formatter = ISO8601DateFormatter()
        let lines = manifest.versions.map { version -> String in
            let words = (try? text(of: version.id)).map(Self.wordCount) ?? 0
            var parts = [version.id, formatter.string(from: version.createdAt), version.source.rawValue, "\(words) words"]
            parts.append(version.parent.map { "started from \($0)" } ?? "started blank")
            parts.append(version.id == manifest.current ? "current (still being written)" : "sealed")
            if version.id == run.versionId { parts.append("← being reviewed") }
            return parts.joined(separator: " · ")
        }
        return lines.joined(separator: "\n")
    }

    func readVersion(_ versionId: String?, start: Int?, end: Int?) throws -> String {
        let id = versionId ?? run.versionId
        let string = try text(of: id) as NSString
        let lower = min(max(start ?? 0, 0), string.length)
        let upper = min(max(end ?? (lower + Self.readLimit), lower), min(string.length, lower + Self.readLimit))
        let range = string.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
        var header = "version \(id), characters \(range.location)–\(NSMaxRange(range)) of \(string.length)"
        if NSMaxRange(range) < string.length {
            header += " (more: call read_version with start \(NSMaxRange(range)))"
        }
        return header + "\n---\n" + string.substring(with: range)
    }

    func diffVersions(from: String, to: String) throws -> String {
        let old = try text(of: from).components(separatedBy: "\n")
        let new = try text(of: to).components(separatedBy: "\n")
        let difference = new.difference(from: old)
        guard !difference.isEmpty else { return "\(from) and \(to) are identical." }
        var removed: [Int: String] = [:]
        var inserted: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let line, _): removed[offset] = line
            case .insert(let offset, let line, _): inserted[offset] = line
            }
        }
        // Walk both texts in step, emitting removed/added lines with a little context.
        var output = ["--- \(from)", "+++ \(to)"]
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if let line = removed[oldIndex] {
                output.append("- " + line)
                oldIndex += 1
            } else if let line = inserted[newIndex] {
                output.append("+ " + line)
                newIndex += 1
            } else {
                if oldIndex < old.count { output.append("  " + old[oldIndex]) }
                oldIndex += 1
                newIndex += 1
            }
        }
        return output.joined(separator: "\n")
    }

    func listAnnotations(versionId: String?) throws -> String {
        let all = try loadAnnotations().filter { versionId == nil || $0.versionId == versionId }
        guard !all.isEmpty else { return "No annotations yet." }
        return all.map(describe).joined(separator: "\n")
    }

    /// One note for the model: id, version, owner, kind, status, then its quote and comment.
    private func describe(_ annotation: Annotation) -> String {
        let owner = annotation.reviewerId == run.reviewerId ? "yours" : "reviewer \(annotation.reviewerId) (read-only)"
        var status = annotation.status.rawValue
        if annotation.status == .dismissed {
            status += " by the writer (unwanted: don't raise it again)"
        } else if let resolution = annotation.resolution {
            status += resolution.by == .user ? " by the writer" : " by reviewer \(resolution.reviewerId ?? "?")"
            if let reason = resolution.reason, !reason.isEmpty { status += ": \(reason)" }
        }
        if annotation.runId == run.runId { status += " · added in this review" }
        var look = annotation.kind
        if let color = annotation.color { look += ", \(color)" }
        if let style = annotation.style { look += ", \(style)" }
        var by = owner
        if !annotation.reviewerId.isEmpty, annotation.reviewerId != run.reviewerId { by = "by \(annotation.reviewerId) (read-only)" }
        if let author = annotation.author { by += " as \(author)" }
        var lines = ["\(annotation.id) · \(annotation.versionId) · \(by) · \(look) · \(status)"]
        if let anchor = annotation.anchor {
            lines.append("  quote: \"\(anchor.quote)\"")
        } else {
            lines.append("  page note (not tied to a passage)")
        }
        lines.append("  comment: \(annotation.comment)")
        return lines.joined(separator: "\n")
    }

    struct NewAnnotation: Decodable, Sendable {
        var versionId: String?
        var quote: String
        var prefix: String?
        var suffix: String?
        var comment: String
        var kind: String?
        var color: String? = nil
        var style: String? = nil
        var author: String? = nil
    }

    struct NewPageNote: Decodable, Sendable {
        var versionId: String?
        var comment: String
        var kind: String?
        var color: String? = nil
        var style: String? = nil
        var author: String? = nil
    }

    /// The label a note gets. Runs with fixed kinds (`run.kinds`) validate against them; otherwise
    /// (agents) any short label is the agent's choice, default "note".
    func label(_ raw: String?) -> (label: String, problem: String?) {
        guard run.kinds == nil else {
            let requested = allowedKind(raw)
            return ((requested.kind ?? defaultKind).rawValue, requested.problem)
        }
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "note" : String(trimmed.prefix(40)), nil)
    }

    /// The agent's colour, if it's one Freewrite can draw ("#RRGGBB", "#RGB" or a name).
    static func checkedColor(_ raw: String?) -> (color: String?, problem: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return (nil, nil) }
        guard NoteStyle.parse(raw) != nil else {
            return (nil, "\"\(raw)\" isn't a colour (use #RRGGBB or one of \(NoteStyle.namedColors.keys.sorted().joined(separator: ", "))); the label's colour is used")
        }
        return (raw, nil)
    }

    static func checkedStyle(_ raw: String?) -> (style: String?, problem: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return (nil, nil) }
        guard ["highlight", "squiggle"].contains(raw) else {
            return (nil, "\"\(raw)\" isn't a style (highlight or squiggle)")
        }
        return (raw, nil)
    }

    /// Anchors and saves a new annotation. `id` comes from the durable tool call, so a call
    /// replayed after a crash finds its annotation instead of adding it twice.
    func addAnnotation(_ new: NewAnnotation, id: String) throws -> String {
        let versionId = new.versionId ?? run.versionId
        let comment = new.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { throw ReviewToolFailure("The comment is empty.") }
        let text = try text(of: versionId)
        let anchor: AnnotationAnchor
        switch AnnotationAnchoring.anchor(quote: new.quote, prefix: new.prefix, suffix: new.suffix, in: text) {
        case .success(let found): anchor = found
        case .failure(let failure): throw ReviewToolFailure(failure.localizedDescription)
        }
        let (kind, kindProblem) = label(new.kind)
        let (color, colorProblem) = Self.checkedColor(new.color)
        let (style, styleProblem) = Self.checkedStyle(new.style)
        try save(Annotation(
            id: id, entryId: run.entryId, versionId: versionId, reviewerId: run.reviewerId, runId: run.runId,
            anchor: anchor, comment: comment, kind: kind,
            status: .active, createdAt: now(), color: color, style: style, author: Self.cleanAuthor(new.author)
        ))
        log(.noteAdd, version: versionId, note: id, author: new.author, detail: "\(kind) \"\(anchor.quote.prefix(80))\"")
        let added = "Added \(id) (\(kind)) on \(versionId) at \(anchor.start)–\(anchor.end): \"\(anchor.quote)\""
        if let kindProblem {
            return added + "\nNote: \(kindProblem); it was saved as \(kind). Change it with update_annotation if another kind fits."
        }
        let problems = [colorProblem, styleProblem].compactMap { $0 }
        return problems.isEmpty ? added : added + "\nNote: " + problems.joined(separator: "; ") + "."
    }

    /// A note about the version as a whole, not tied to a passage (shown at the top of the margin).
    func addPageNote(_ new: NewPageNote, id: String) throws -> String {
        let versionId = new.versionId ?? run.versionId
        let comment = new.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { throw ReviewToolFailure("The comment is empty.") }
        guard manifest.version(versionId) != nil else {
            throw ReviewToolFailure("No version \(versionId). Call list_versions to see the ids.")
        }
        let (kind, kindProblem) = label(new.kind)
        let (color, colorProblem) = Self.checkedColor(new.color)
        let (style, _) = Self.checkedStyle(new.style)
        try save(Annotation(
            id: id, entryId: run.entryId, versionId: versionId, reviewerId: run.reviewerId, runId: run.runId,
            anchor: nil, comment: comment, kind: kind, status: .active, createdAt: now(),
            color: color, style: style, author: Self.cleanAuthor(new.author)
        ))
        log(.noteAdd, version: versionId, note: id, author: new.author, detail: "\(kind) (page note)")
        let added = "Added page note \(id) (\(kind)) on \(versionId)."
        let problems = [kindProblem.map { "\($0); it was saved as \(kind)" }, colorProblem].compactMap { $0 }
        return problems.isEmpty ? added : added + "\nNote: " + problems.joined(separator: "; ") + "."
    }

    /// Appends a note unless the same durable call already did.
    private func save(_ annotation: Annotation) throws {
        try mutate { annotations in
            guard !annotations.contains(where: { $0.id == annotation.id }) else { return }
            annotations.append(annotation)
        }
    }

    func updateAnnotation(id: String, comment: String?, kind: String?, color: String? = nil, style: String? = nil) throws -> String {
        // With fixed kinds, a bad one keeps the old kind; free labels take any non-empty word.
        let newKind: String?
        var problem: String?
        if run.kinds != nil {
            let requested = allowedKind(kind)
            newKind = requested.kind?.rawValue
            problem = requested.problem.map { "kept its kind: \($0)" }
        } else {
            newKind = kind.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label($0).label }
        }
        let (newColor, colorProblem) = Self.checkedColor(color)
        let (newStyle, styleProblem) = Self.checkedStyle(style)
        try mutate { annotations in
            let index = try ownIndex(of: id, in: annotations)
            if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
                annotations[index].comment = comment
            }
            if let newKind { annotations[index].kind = newKind }
            if let newColor { annotations[index].color = newColor }
            if let newStyle { annotations[index].style = newStyle }
        }
        log(.noteUpdate, note: id, detail: [newKind, newColor, newStyle].compactMap { $0 }.joined(separator: ", "))
        let problems = [problem, colorProblem, styleProblem].compactMap { $0 }
        guard !problems.isEmpty else { return "Updated \(id)." }
        return "Updated \(id), but " + problems.joined(separator: "; ") + "."
    }

    /// Records an agent's step in the entry's log.
    private func log(_ op: EntryEvent.Op, version: String? = nil, note: String? = nil, author: String? = nil, detail: String? = nil) {
        versionStore.appendLog(EntryEvent(
            at: now(), actor: run.reviewerId.isEmpty ? "agent" : run.reviewerId, author: Self.cleanAuthor(author),
            op: op, version: version, note: note, detail: detail.flatMap { $0.isEmpty ? nil : $0 }), for: run.entryFilename)
    }

    private static func cleanAuthor(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return String(raw.prefix(40))
    }

    func removeAnnotation(id: String) throws -> String {
        try mutate { annotations in
            let index = try ownIndex(of: id, in: annotations)
            annotations.remove(at: index)
        }
        log(.noteRemove, note: id)
        return "Removed \(id)."
    }

    /// Marks one of this reviewer's earlier open notes resolved because the writing now
    /// addresses it. Other reviewers' notes are read-only; notes from this same review are
    /// removed (remove_annotation), not resolved. Resolving twice is not an error.
    func resolveAnnotation(id: String, reason: String) throws -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw ReviewToolFailure("Say in a few words what addressed it (e.g. \"fixed in v3\").")
        }
        let resolution = Annotation.Resolution(by: .reviewer, reviewerId: run.reviewerId, runId: run.runId, reason: reason, at: now())
        return try mutate { annotations -> String in
            let index = try ownIndex(of: id, in: annotations)
            let note = annotations[index]
            switch note.status {
            case .resolved:
                return "\(id) is already resolved."
            case .dismissed:
                throw ReviewToolFailure("The writer dismissed \(id); leave it alone and don't raise it again.")
            case .active, .orphaned:
                guard note.runId != run.runId else {
                    throw ReviewToolFailure("\(id) was added in this review; use remove_annotation if it no longer applies.")
                }
                annotations[index].resolve(resolution)
                log(.noteResolve, version: note.versionId, note: id, detail: reason)
                return "Resolved \(id)."
            }
        }
    }

    private func ownIndex(of id: String, in annotations: [Annotation]) throws -> Int {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            throw ReviewToolFailure("No annotation \(id). Call list_annotations to see the ids.")
        }
        guard annotations[index].reviewerId == run.reviewerId else {
            throw ReviewToolFailure("\(id) belongs to another reviewer; you can only change your own.")
        }
        return index
    }

    private func loadAnnotations() throws -> [Annotation] {
        do {
            return try annotations.load(for: run.entryFilename)
        } catch {
            throw ReviewToolFailure("annotations.json can't be read: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func mutate<T>(_ change: (inout [Annotation]) throws -> T) throws -> T {
        do {
            return try annotations.update(for: run.entryFilename, change)
        } catch let failure as ReviewToolFailure {
            throw failure
        } catch {
            throw ReviewToolFailure("Couldn't save annotations: \(error.localizedDescription)")
        }
    }

    func finishReview(summary: String) throws -> String {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "Review finished." }
        do {
            try annotations.saveSummary(summary, reviewerName: run.reviewerName, versionId: run.versionId,
                                        entryFilename: run.entryFilename, now: now())
        } catch {
            throw ReviewToolFailure("Couldn't save the summary: \(error.localizedDescription)")
        }
        log(.replyPost, version: run.versionId, author: run.reviewerName, detail: String(summary.prefix(80)))
        return "Review finished."
    }

    /// The first message of a run: what to review, the version list, and (when short) the text itself.
    func brief() -> String {
        var lines = [
            "Review version \(run.versionId) of this journal entry.",
            run.scope == .all
                ? "Read every version (list_versions, read_version, diff_versions) and also comment on how the writing changed between them."
                : "Focus on \(run.versionId); look at other versions only if it helps.",
            "",
            "<versions>",
            (try? listVersions()) ?? "",
            "</versions>",
        ]
        if let text = try? text(of: run.versionId), (text as NSString).length <= 12_000 {
            lines += ["", "<entry_text version=\"\(run.versionId)\">", text, "</entry_text>"]
        } else {
            lines += ["", "The text is long: read it with read_version in slices."]
        }
        lines += ["", "Kinds you may use (pass one as kind on every note; default \(defaultKind.rawValue)):"]
        lines += allowedKinds.map { "- \($0.rawValue): \($0.guidance)" }
        lines += earlierNotes()
        lines += ["", "Add your notes with add_annotation (a passage) or add_page_note (the version as a whole), then call finish_review."]
        return lines.joined(separator: "\n")
    }

    /// Most notes listed in the brief; the rest are a list_annotations call away.
    static let briefNoteLimit = 40

    /// The notes earlier reviews left on this entry (this version first), so a new review can
    /// resolve its own notes the writing now addresses and doesn't repeat any of them. Notes on
    /// other versions aren't carried over: they're listed for reference, and a reviewer re-adds
    /// one on this version if it still applies.
    func earlierNotes() -> [String] {
        guard let all = try? loadAnnotations().filter({ $0.runId != run.runId }), !all.isEmpty else { return [] }
        let ordered = all.filter { $0.versionId == run.versionId } + all.filter { $0.versionId != run.versionId }
        let mine = ordered.filter { $0.reviewerId == run.reviewerId && $0.isOpen }
        var lines = [
            "",
            "Earlier notes on this entry (\(all.count)). Before adding notes, check them against the text you're reviewing:",
            "- Your own open notes that the writing now addresses (fixed, rewritten, answered): call resolve_annotation with the id and a short reason.",
            "- Don't repeat a note already on the version you're reviewing, or one that was resolved or dismissed (dismissed means the writer didn't want it).",
            "- An open note on an earlier version that still applies to this text: add it again here (the writer only sees this version's notes), then resolve the old one if it's yours.",
            "- Other reviewers' notes are read-only context.",
        ]
        if !mine.isEmpty {
            lines.append("You have \(mine.count) open note(s) to check.")
        }
        lines += ["", "<earlier_notes>"]
        lines += ordered.prefix(Self.briefNoteLimit).map(describe)
        if ordered.count > Self.briefNoteLimit {
            lines.append("(\(ordered.count - Self.briefNoteLimit) more: call list_annotations)")
        }
        lines.append("</earlier_notes>")
        return lines
    }
}
