//
//  ReviewerBuilder.swift
//  freewrite
//
//  "New Reviewer by Chat…": a small chat that creates or edits a `ReviewerProfile` from a
//  description. Runs on PiDurableKit like reviews, but in its own in-memory harness with its own
//  core extension (`freewrite-reviewer-builder`): the model only gets the builder tools below,
//  never an entry. `propose_reviewer` validates like Settings › Agents and returns a draft; it
//  never saves. Only the user's Save in the sheet writes `UserDefaults["reviewers"]`.
//

import Foundation
import Observation
import PiDurableKit

// MARK: - Catalog

/// A model a reviewer can use, from the bundled catalog of a configured provider.
struct ReviewerModelOption: Equatable, Sendable {
    /// "provider/modelId", as stored in `ReviewerProfile.model`.
    var id: String { "\(provider)/\(modelId)" }
    var provider: String
    var providerTitle: String
    var modelId: String
    var name: String
    /// Levels the model supports, without "off" (as the Settings editor offers them).
    var thinkingLevels: [String]
}

extension ReviewerModelOption {
    init(_ info: ModelInfo, providerTitle: String) {
        self.init(
            provider: info.provider.rawValue, providerTitle: providerTitle, modelId: info.modelId, name: info.name,
            thinkingLevels: info.thinkingLevels.map(\.rawValue).filter { $0 != "off" })
    }
}

/// What the builder may offer: the configured providers' models, and what "Automatic" means now.
struct ReviewerBuilderCatalog: Equatable, Sendable {
    /// Configured providers' titles, in the order Automatic tries them.
    var providers: [String]
    var models: [ReviewerModelOption]
    /// The model a reviewer set to Automatic runs on now ("provider/modelId"), nil when nothing is configured.
    var automaticModel: String?

    static let empty = ReviewerBuilderCatalog(providers: [], models: [], automaticModel: nil)

    func model(_ id: String) -> ReviewerModelOption? {
        models.first { $0.id == id }
    }

    /// A model's name for people: "Automatic", its catalog name, else the raw id.
    func displayName(_ id: String) -> String {
        id.isEmpty ? "Automatic" : (model(id)?.name ?? id)
    }
}

// MARK: - Proposals (pure)

/// One field a proposal changes on a saved reviewer.
struct ReviewerFieldChange: Equatable, Sendable, Identifiable {
    var field: String
    var before: String
    var after: String
    var id: String { field }
}

/// A normalised draft from `propose_reviewer`, waiting for the user's Save.
struct ReviewerProposal: Equatable, Sendable, Identifiable {
    var id = UUID()
    var draft: ReviewerProfile
    /// The saved reviewer this would replace; nil for a new one.
    var original: ReviewerProfile?
    /// What changes compared to `original` (empty for a new reviewer).
    var changes: [ReviewerFieldChange]

    var isNew: Bool { original == nil }
}

/// What `propose_reviewer` receives. Every field is optional when editing (missing = keep).
struct ReviewerProposalInput: Decodable, Sendable, Equatable {
    var id: String?
    var name: String?
    var instructions: String?
    var model: String?
    var thinkingLevel: String?
    var color: String?
    var scope: String?
    var autoRun: Bool?
    var kinds: [String]?
    var defaultKind: String?

    init(
        id: String? = nil, name: String? = nil, instructions: String? = nil, model: String? = nil,
        thinkingLevel: String? = nil, color: String? = nil, scope: String? = nil, autoRun: Bool? = nil,
        kinds: [String]? = nil, defaultKind: String? = nil
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.color = color
        self.scope = scope
        self.autoRun = autoRun
        self.kinds = kinds
        self.defaultKind = defaultKind
    }
}

/// The logic behind the builder tools. No model involved, so it's unit-tested directly;
/// `ReviewerChatService` wraps each function in a PiDurableKit `Tool`.
struct ReviewerBuilderToolbox {
    /// Saved reviewers (`UserDefaults["reviewers"]`).
    var profiles: [ReviewerProfile]
    var catalog: ReviewerBuilderCatalog
    /// New reviewers proposed earlier in this chat and not saved yet, by id, so a revision keeps its id.
    var drafts: [String: ReviewerProfile] = [:]

    static let maxNameLength = 60

    // MARK: Reading

    func listReviewers() -> String {
        guard !profiles.isEmpty else { return "No reviewers yet." }
        return profiles.map { profile in
            let firstLine = profile.instructions.split(separator: "\n").first.map(String.init) ?? ""
            return "\(profile.id) · \(profile.name) · \(catalog.displayName(profile.model)) · kinds: "
                + profile.kinds.map(\.rawValue).joined(separator: ", ")
                + "\n  " + (firstLine.count > 140 ? firstLine.prefix(140) + "…" : firstLine)
        }.joined(separator: "\n")
    }

    func getReviewer(_ id: String) throws -> String {
        guard let profile = find(id) else {
            throw ReviewToolFailure("No reviewer \"\(id)\". Call list_reviewers to see the ids.")
        }
        return describe(profile)
    }

    func listModels() -> String {
        guard !catalog.providers.isEmpty else {
            return "No provider is set up yet; reviewers can only use Automatic until one is added in Settings › Agents."
        }
        var lines = ["Automatic (model \"\"): " + (catalog.automaticModel.map { "now \(catalog.displayName($0)) (\($0))" } ?? "nothing configured")]
        for provider in catalog.providers {
            lines.append("")
            lines.append(provider + ":")
            for model in catalog.models where model.providerTitle == provider {
                let thinking = model.thinkingLevels.isEmpty ? "no thinking levels" : "thinking: " + model.thinkingLevels.joined(separator: ", ")
                lines.append("- \(model.id) · \(model.name) · \(thinking)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func listKinds() -> String {
        AnnotationKind.allCases.map { "- \($0.rawValue): \($0.guidance)" }.joined(separator: "\n")
    }

    /// A reviewer in full, as the tools show it.
    func describe(_ profile: ReviewerProfile) -> String {
        [
            "id: \(profile.id)",
            "name: \(profile.name)",
            "model: " + (profile.model.isEmpty ? "\"\" (Automatic)" : "\(profile.model) (\(catalog.displayName(profile.model)))"),
            "thinkingLevel: \(profile.thinkingLevel ?? "default")",
            "color: \(profile.color.rawValue)",
            "scope: \(profile.scope.rawValue)",
            "autoRun: \(profile.autoRunOnNewVersion)",
            "kinds: " + profile.kinds.map(\.rawValue).joined(separator: ", "),
            "defaultKind: \(profile.effectiveDefaultKind.rawValue)",
            "instructions:",
            profile.instructions,
        ].joined(separator: "\n")
    }

    private func find(_ id: String) -> ReviewerProfile? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.first { $0.id == trimmed }
            ?? drafts[trimmed]
            ?? profiles.first { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    // MARK: Proposing

    /// Validates a proposal the way the Settings editor constrains a reviewer and returns the
    /// normalised draft. Nothing is saved.
    func propose(_ input: ReviewerProposalInput) throws -> ReviewerProposal {
        var problems: [String] = []
        let original: ReviewerProfile?
        var draft: ReviewerProfile
        if let id = input.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            guard let base = find(id) else {
                throw ReviewToolFailure("No reviewer \"\(id)\". Leave id out to create a new reviewer, or call list_reviewers to see the ids.")
            }
            original = profiles.first { $0.id == base.id }
            draft = base
        } else {
            original = nil
            draft = ReviewerProfile(
                name: "", instructions: "",
                color: ReviewerColor.allCases[profiles.count % ReviewerColor.allCases.count])
        }

        if let name = input.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                problems.append("name can't be empty")
            } else if trimmed.count > Self.maxNameLength {
                problems.append("name is too long (at most \(Self.maxNameLength) characters)")
            } else {
                draft.name = trimmed
            }
        } else if draft.name.isEmpty {
            problems.append("a new reviewer needs a name")
        }

        if let instructions = input.instructions {
            let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { problems.append("instructions can't be empty") } else { draft.instructions = trimmed }
        } else if draft.instructions.isEmpty {
            problems.append("a new reviewer needs instructions (how to review, in the second person)")
        }

        let modelBefore = draft.model
        if let raw = input.model {
            switch resolveModel(raw) {
            case .success(let id): draft.model = id
            case .failure(let failure): problems.append(failure.message)
            }
        }

        // Thinking levels depend on the model, like the editor's Thinking picker.
        let levels = catalog.model(draft.model)?.thinkingLevels ?? []
        if let raw = input.thinkingLevel {
            let level = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if level.isEmpty || level == "default" {
                draft.thinkingLevel = nil
            } else if draft.model.isEmpty {
                problems.append("thinkingLevel needs a model: Automatic always uses the model's default")
            } else if levels.isEmpty {
                problems.append("\(catalog.displayName(draft.model)) has no thinking levels; leave thinkingLevel out")
            } else if levels.contains(level) {
                draft.thinkingLevel = level
            } else {
                problems.append("\(catalog.displayName(draft.model)) supports thinking levels \(levels.joined(separator: ", ")), not \"\(raw)\"")
            }
        } else if draft.model != modelBefore, let level = draft.thinkingLevel, !levels.contains(level) {
            // The new model can't use the old level.
            draft.thinkingLevel = nil
        }

        if let raw = input.color {
            if let color = ReviewerColor(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                draft.color = color
            } else {
                problems.append("color \"\(raw)\" isn't one of: " + ReviewerColor.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }

        if let raw = input.scope {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "latest", "version", "one", "current": draft.scope = .latest
            case "all", "all versions": draft.scope = .all
            default: problems.append("scope must be \"latest\" (the version under review) or \"all\" (every version)")
            }
        }

        if let autoRun = input.autoRun { draft.autoRunOnNewVersion = autoRun }

        let allKinds = AnnotationKind.allCases.map(\.rawValue).joined(separator: ", ")
        if let raw = input.kinds {
            let parsed = raw.map { ($0, AnnotationKind.parse($0)) }
            let unknown = parsed.filter { $0.1 == nil }.map { "\"\($0.0)\"" }
            if !unknown.isEmpty {
                problems.append("unknown kind(s) \(unknown.joined(separator: ", ")); use: \(allKinds)")
            } else if parsed.isEmpty {
                problems.append("kinds needs at least one kind")
            } else {
                draft.kinds = parsed.compactMap(\.1)
            }
        }

        if let raw = input.defaultKind {
            if let kind = AnnotationKind.parse(raw) {
                if draft.kinds.contains(kind) {
                    draft.defaultKind = kind
                } else {
                    problems.append("defaultKind must be one of the reviewer's kinds (" + draft.kinds.map(\.rawValue).joined(separator: ", ") + "), not \(kind.rawValue)")
                }
            } else {
                problems.append("defaultKind \"\(raw)\" isn't a kind; use: \(allKinds)")
            }
        }
        draft.defaultKind = draft.effectiveDefaultKind

        guard problems.isEmpty else {
            throw ReviewToolFailure("Not proposed: " + problems.joined(separator: "; ") + ".")
        }
        let changes = original.map { Self.changes(from: $0, to: draft, catalog: catalog) } ?? []
        if original != nil, changes.isEmpty {
            throw ReviewToolFailure("Nothing would change: \(draft.name) already has these settings.")
        }
        return ReviewerProposal(draft: draft, original: original, changes: changes)
    }

    /// "" for Automatic, else a catalog id; accepts "provider/modelId", a bare model id or the model's name.
    func resolveModel(_ raw: String) -> Result<String, ReviewToolFailure> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || ["automatic", "auto", "default"].contains(value.lowercased()) { return .success("") }
        if let model = catalog.model(value) { return .success(model.id) }
        let matches = catalog.models.filter {
            $0.modelId.caseInsensitiveCompare(value) == .orderedSame || $0.name.caseInsensitiveCompare(value) == .orderedSame
        }
        if matches.count == 1 { return .success(matches[0].id) }
        if matches.count > 1 {
            return .failure(ReviewToolFailure("model \"\(value)\" is ambiguous (" + matches.map(\.id).joined(separator: ", ") + "); pass provider/modelId"))
        }
        let provider = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        if let known = ReviewProvider(rawValue: provider.lowercased()), !catalog.providers.contains(known.title) {
            return .failure(ReviewToolFailure("\(known.title) isn't set up in Settings › Agents, so its models can't be used; call list_models"))
        }
        return .failure(ReviewToolFailure("unknown model \"\(value)\"; call list_models for the ids, or use \"\" for Automatic"))
    }

    /// The fields that differ, in the editor's order and words.
    static func changes(from old: ReviewerProfile, to new: ReviewerProfile, catalog: ReviewerBuilderCatalog) -> [ReviewerFieldChange] {
        func kinds(_ profile: ReviewerProfile) -> String { profile.kinds.map(\.title).joined(separator: ", ") }
        func scope(_ profile: ReviewerProfile) -> String { profile.scope == .all ? "All versions" : "The version under review" }
        let fields: [(String, (ReviewerProfile) -> String)] = [
            ("Name", \.name),
            ("Colour", { $0.color.title }),
            ("Model", { catalog.displayName($0.model) }),
            ("Thinking", { $0.thinkingLevel?.capitalized ?? "Default" }),
            ("Reads", scope),
            ("Run on New Version", { $0.autoRunOnNewVersion ? "On" : "Off" }),
            ("Kinds", kinds),
            ("Default kind", { $0.effectiveDefaultKind.title }),
            ("Instructions", \.instructions),
        ]
        return fields.compactMap { field, value in
            let before = value(old)
            let after = value(new)
            return before == after ? nil : ReviewerFieldChange(field: field, before: before, after: after)
        }
    }

    /// The tool result for a proposal: what the model needs to talk about it and revise it.
    func summary(of proposal: ReviewerProposal) -> String {
        var lines = [proposal.isNew
            ? "Draft of a new reviewer, shown to the user with Save and Keep chatting. Not saved."
            : "Draft of changes to \(proposal.original?.name ?? proposal.draft.name), shown to the user with Save and Keep chatting. Not saved."]
        lines.append("To revise it, call propose_reviewer again with id \(proposal.draft.id).")
        lines.append("")
        lines.append(describe(proposal.draft))
        if !proposal.changes.isEmpty {
            lines.append("")
            lines.append("Changes: " + proposal.changes.map(\.field).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Chat transcript (pure)

struct ReviewerChatMessage: Equatable, Sendable, Identifiable {
    enum Role: Sendable { case user, assistant }
    var id: String
    var role: Role
    var text: String
}

extension ReviewerChatMessage {
    /// User and assistant text of a transcript, oldest first. Failed answers are left out (the
    /// sheet shows the error with Retry), and a message sent again by Retry shows once.
    static func transcript(_ entries: [Entry]) -> [ReviewerChatMessage] {
        var messages: [ReviewerChatMessage] = []
        var failedUserIndex: Int?
        for entry in entries {
            if let user = entry.userMessage {
                let text = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let failed = failedUserIndex, messages[failed].text == text {
                    messages.remove(at: failed)
                }
                failedUserIndex = nil
                messages.append(ReviewerChatMessage(id: entry.id.description, role: .user, text: text))
            } else if let assistant = entry.assistantMessage {
                if assistant.stopReason == .error {
                    failedUserIndex = messages.lastIndex { $0.role == .user }
                    continue
                }
                let text = assistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                messages.append(ReviewerChatMessage(id: entry.id.description, role: .assistant, text: text))
            }
        }
        return messages
    }
}

// MARK: - Chat session

/// One open chat: what the sheet shows. Lives as long as the sheet.
@MainActor
@Observable
final class ReviewerChat: Identifiable {
    let id = UUID()
    /// The reviewer the chat was opened from ("Edit with Chat…"); nil for a new one.
    let editing: ReviewerProfile?

    var messages: [ReviewerChatMessage] = []
    /// The answer being written right now.
    var streamingText = ""
    var activity: String?
    var isRunning = false
    var error: String?
    var proposal: ReviewerProposal?
    /// Name of the reviewer the user just saved, for the confirmation line.
    var savedName: String?
    /// Unsaved new reviewers proposed in this chat, by id.
    var drafts: [String: ReviewerProfile] = [:]

    var lastSubmitted: String?
    var conversation: Conversation?
    var watcher: Task<Void, Never>?
    var stopRequested = false
    var submissions = 0

    init(editing: ReviewerProfile? = nil) {
        self.editing = editing
    }

    func apply(_ view: ConversationView) {
        messages = ReviewerChatMessage.transcript(view.entries)
        streamingText = view.isBusy ? (view.streamingMessage?.text ?? "") : ""
        if let tool = view.live.tools.last(where: { $0.status != .done }) {
            activity = Self.activity(for: tool.name)
        } else {
            activity = nil
        }
    }

    static func activity(for tool: String) -> String {
        switch tool {
        case "list_reviewers", "get_reviewer": return "Looking at your reviewers…"
        case "list_models": return "Checking the models…"
        case "list_kinds": return "Checking the kinds of notes…"
        case "propose_reviewer": return "Drafting the reviewer…"
        default: return "Working…"
        }
    }
}

/// Which chat Settings › Agents should show. ⌘K and the Agents pane ask for one here; the pane
/// presents it as a sheet on the Settings window.
@MainActor
@Observable
final class ReviewerChatLauncher {
    static let shared = ReviewerChatLauncher()
    var chat: ReviewerChat?

    func open(editing: ReviewerProfile? = nil) {
        if let chat, chat.editing?.id == editing?.id { return }
        if let chat { ReviewerChatService.shared.close(chat) }
        chat = ReviewerChat(editing: editing)
    }
}

// MARK: - Service

@MainActor
final class ReviewerChatService {
    static let shared = ReviewerChatService()

    static let extensionName = "freewrite-reviewer-builder"
    nonisolated static let toolNames: Set<String> = [
        "list_reviewers", "get_reviewer", "list_models", "list_kinds", "propose_reviewer",
    ]

    static let systemPrompt = """
    You help someone set up a reviewer in Freewrite, a private journaling app. A reviewer is an AI that \
    reads one of their entries and leaves short margin notes of certain kinds. You never see their entries; \
    you only shape reviewers.

    - Work out what they want with as few questions as possible; when the description is clear enough, \
    propose right away. Ask at most one short question at a time.
    - Write the reviewer's instructions in the second person ("You read as…"), concrete and in the person's \
    spirit: what to look for, tone, how many notes, what to skip. Freewrite already tells every reviewer \
    to quote exactly, annotate rather than rewrite, and be kind, so don't repeat that.
    - Pick kinds that match the request (call list_kinds), and a default kind among them. Leave the model \
    Automatic ("") unless they ask for a provider or model; then call list_models and use an id from it.
    - propose_reviewer only shows a draft with Save and Keep chatting; it doesn't save. After proposing, \
    say in one or two sentences what you set up. To revise a draft or edit a saved reviewer, pass its id.
    - If a tool says something is invalid, fix it and propose again. Use only your tools. Keep replies short.
    """

    private let makeModels: @MainActor () async throws -> Models
    private let resolveModel: @MainActor () async throws -> ModelRef
    private let loadCatalog: @MainActor () async -> ReviewerBuilderCatalog
    private let loadProfiles: @MainActor () -> [ReviewerProfile]
    private var harness: Harness?
    private var opening: Task<Harness, Error>?
    private var chats: [ConversationID: ReviewerChat] = [:]

    /// - Parameters:
    ///   - makeModels: The model collection (the app shares the reviews' one: same runtime and credentials).
    ///   - resolveModel: The model the chat runs on (the app: reviews' Automatic choice).
    ///   - loadCatalog: The configured providers' models.
    ///   - loadProfiles: The saved reviewers.
    init(
        makeModels: @escaping @MainActor () async throws -> Models = { try await ReviewService.shared.models() },
        resolveModel: @escaping @MainActor () async throws -> ModelRef = {
            try await ReviewService.shared.resolveModel(for: ReviewerProfile(name: "", instructions: "", color: .yellow))
        },
        loadCatalog: @escaping @MainActor () async -> ReviewerBuilderCatalog = { await ReviewerChatService.appCatalog() },
        loadProfiles: @escaping @MainActor () -> [ReviewerProfile] = { ReviewerStore.load() }
    ) {
        self.makeModels = makeModels
        self.resolveModel = resolveModel
        self.loadCatalog = loadCatalog
        self.loadProfiles = loadProfiles
    }

    /// The configured providers' chat models from the bundled catalog, like the Settings editor's model list.
    static func appCatalog() async -> ReviewerBuilderCatalog {
        let reviews = ReviewService.shared
        var providers: [String] = []
        var models: [ReviewerModelOption] = []
        var automatic: String?
        for provider in ReviewProvider.allCases {
            guard (try? await reviews.credentials.credential(for: provider.providerID)) != nil else { continue }
            providers.append(provider.title)
            if automatic == nil { automatic = "\(provider.rawValue)/\(provider.defaultModelID)" }
            models += await reviews.availableModels(for: provider)
                .filter { !$0.modelId.contains("realtime") }
                .map { ReviewerModelOption($0, providerTitle: provider.title) }
        }
        return ReviewerBuilderCatalog(providers: providers, models: models, automaticModel: automatic)
    }

    // MARK: Harness

    /// A sibling of the reviews' harness, in memory: a chat only lives as long as its sheet, so
    /// nothing needs to survive a quit, and the reviews' harness (with its own extension and tool
    /// guard) stays untouched. Both share one `Models`, so one JavaScript runtime.
    private func openHarness() async throws -> Harness {
        if let harness { return harness }
        if let opening { return try await opening.value }
        let task = Task<Harness, Error> { @MainActor in
            try await Harness.open(.memory, models: try await makeModels(), extensions: [builderExtension()])
        }
        opening = task
        defer { opening = nil }
        let harness = try await task.value
        self.harness = harness
        return harness
    }

    func shutdown() async {
        try? await harness?.close()
        harness = nil
    }

    private func builderExtension() -> Extension {
        let guardHook = Hook.beforeTool { call, _ in
            Self.toolNames.contains(call.name) ? .allow : .block("\(call.name) isn't available here.")
        }
        return Extension(
            Self.extensionName, tools: makeTools(),
            sections: [PromptSection("freewrite_reviewer_builder", text: Self.systemPrompt)],
            hooks: [guardHook]
        )
    }

    // MARK: Chatting

    /// Sends what the user typed and waits for the answer. Errors land in `chat.error`.
    func send(_ text: String, in chat: ReviewerChat) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isRunning else { return }
        chat.isRunning = true
        chat.error = nil
        chat.stopRequested = false
        chat.lastSubmitted = text
        chat.savedName = nil
        defer {
            chat.isRunning = false
            chat.activity = nil
            chat.streamingText = ""
        }
        do {
            let conversation = try await conversation(for: chat)
            chat.submissions += 1
            let record = try await conversation.submit(text, requestId: "\(chat.id.uuidString):\(chat.submissions)").wait()
            if let view = try? await conversation.view() { chat.apply(view) }
            guard !chat.stopRequested else { return }
            try await checkOutcome(record, in: conversation)
        } catch {
            guard !chat.stopRequested else { return }
            chat.error = Self.describe(error)
        }
    }

    /// Sends the last message again after an error.
    func retry(in chat: ReviewerChat) async {
        guard let text = chat.lastSubmitted else { return }
        await send(text, in: chat)
    }

    func stop(_ chat: ReviewerChat) {
        guard chat.isRunning else { return }
        chat.stopRequested = true
        if let conversation = chat.conversation {
            Task { try? await conversation.abort() }
        }
    }

    /// The sheet closed: stop and forget the chat.
    func close(_ chat: ReviewerChat) {
        stop(chat)
        chat.watcher?.cancel()
        chat.watcher = nil
        if let id = chat.conversation?.id { chats[id] = nil }
        chat.conversation = nil
    }

    private func conversation(for chat: ReviewerChat) async throws -> Conversation {
        if let conversation = chat.conversation { return conversation }
        let model: ModelRef
        do {
            model = try await resolveModel()
        } catch {
            throw ReviewError.notConfigured
        }
        let harness = try await openHarness()
        let conversation = try await harness.createConversation(agent: AgentChange(model: model, instructions: Self.seed(for: chat.editing)))
        chat.conversation = conversation
        chats[conversation.id] = chat
        chat.watcher = Task { [weak chat] in
            do {
                for try await view in conversation.views() {
                    guard let chat else { return }
                    chat.apply(view)
                }
            } catch {}
        }
        return conversation
    }

    /// Extra instructions for a chat opened from a reviewer ("Edit with Chat…").
    static func seed(for profile: ReviewerProfile?) -> String? {
        guard let profile else { return nil }
        return "The user opened this chat from their reviewer \"\(profile.name)\" (id \(profile.id)) to change it. "
            + "Unless they ask for a new reviewer, changes apply to that one: read it with get_reviewer first and pass its id to propose_reviewer."
    }

    private func checkOutcome(_ record: SubmissionRecord, in conversation: Conversation) async throws {
        switch record.status {
        case .done(_, let answer?):
            if let message = try await conversation.entry(answer)?.assistantMessage, message.stopReason == .error {
                throw ReviewError.failed(ReviewService.friendly(message.errorMessage ?? "The model returned an error."))
            }
        case .done(_, nil):
            return
        case .unanswered(_, let reason, let detail):
            let message = detail?["message"]?.stringValue ?? detail?["error"]?.stringValue ?? detail?.stringValue
            throw ReviewError.failed(ReviewService.friendly(message.map { "\(reason): \($0)" } ?? reason))
        case .queued, .placed:
            throw ReviewError.failed("The chat is still running.")
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? ReviewError { return error.localizedDescription }
        return ReviewService.friendly(error.localizedDescription)
    }

    // MARK: Tools

    private struct IdArguments: Decodable, Sendable { var id: String }

    /// Runs a toolbox function for the chat that owns the calling conversation, with the reviewers
    /// and models as they are now.
    private func withToolbox(
        _ context: ToolCallContext, _ body: @MainActor (ReviewerBuilderToolbox, ReviewerChat) throws -> String
    ) async -> ToolResult {
        guard let chat = chats[context.conversationId] else {
            return ToolResult.error("This chat was closed. Don't call any more tools.").terminating()
        }
        let catalog = await loadCatalog()
        let toolbox = ReviewerBuilderToolbox(profiles: loadProfiles(), catalog: catalog, drafts: chat.drafts)
        do {
            return .text(try body(toolbox, chat))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func makeTools() -> [Tool] {
        let kinds = AnnotationKind.allCases.map(\.rawValue).joined(separator: ", ")
        let colors = ReviewerColor.allCases.map(\.rawValue).joined(separator: ", ")
        return [
            Tool("list_reviewers", description: "Lists the saved reviewers: id, name, model, kinds and the first line of their instructions.",
                 replay: .safe) { [weak self] context in
                await self?.withToolbox(context) { toolbox, _ in toolbox.listReviewers() } ?? .error("Freewrite is closing.")
            },
            Tool("get_reviewer", description: "Shows one reviewer in full, including its instructions.",
                 parameters: .object(["id": .string("Reviewer id (or name)")]),
                 replay: .safe) { [weak self] (arguments: IdArguments, context) in
                await self?.withToolbox(context) { toolbox, _ in try toolbox.getReviewer(arguments.id) } ?? .error("Freewrite is closing.")
            },
            Tool("list_models", description: "Lists the models of the providers set up on this Mac, with their thinking levels, and what Automatic uses.",
                 replay: .safe) { [weak self] context in
                await self?.withToolbox(context) { toolbox, _ in toolbox.listModels() } ?? .error("Freewrite is closing.")
            },
            Tool("list_kinds", description: "Lists the kinds of notes a reviewer can leave, with what each is for.",
                 replay: .safe) { [weak self] context in
                await self?.withToolbox(context) { toolbox, _ in toolbox.listKinds() } ?? .error("Freewrite is closing.")
            },
            Tool("propose_reviewer", description: "Shows the user a draft reviewer (new, or changes to an existing one with id) with Save and Keep chatting. Validates every field; nothing is saved until the user clicks Save. When editing, leave out the fields that stay the same.",
                 parameters: .object([
                    "id": .string("Id of the reviewer or draft to change; leave out for a new reviewer").optional,
                    "name": .string("Short name, e.g. Harsh Editor (required for a new reviewer)").optional,
                    "instructions": .string("How to review, in the second person (required for a new reviewer)").optional,
                    "model": .string("provider/modelId from list_models, or \"\" for Automatic").optional,
                    "thinkingLevel": .string("One of the model's thinking levels from list_models, or \"default\"").optional,
                    "color": .string("The reviewer's dot colour: \(colors)").optional,
                    "scope": .string("\"latest\": the version under review; \"all\": every version, to comment on how it changed").optional,
                    "autoRun": .boolean("Review automatically each time the writer seals a New Version").optional,
                    "kinds": .array(of: .string("A kind: \(kinds)"), description: "Kinds of notes it may leave (at least one)").optional,
                    "defaultKind": .string("Kind used when a note doesn't name one; must be one of kinds").optional,
                 ]), replay: .safe) { [weak self] (arguments: ReviewerProposalInput, context) in
                await self?.withToolbox(context) { toolbox, chat in
                    let proposal = try toolbox.propose(arguments)
                    if proposal.isNew { chat.drafts[proposal.draft.id] = proposal.draft }
                    chat.proposal = proposal
                    return toolbox.summary(of: proposal)
                } ?? .error("Freewrite is closing.")
            },
        ]
    }
}
