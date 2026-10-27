//
//  ReviewerBuilderTests.swift
//  freewriteTests
//
//  "New Reviewer by Chat…": the builder toolbox (validation, normalisation, edit diff) and an
//  end-to-end chat with PiDurableKit's scripted FauxProvider (no network, no keys).
//

import Foundation
import PiDurableKit
import Testing
@testable import freewrite

struct ReviewerBuilderToolboxTests {
    private let catalog = ReviewerBuilderCatalog(
        providers: ["OpenAI (ChatGPT)"],
        models: [
            ReviewerModelOption(provider: "openai", providerTitle: "OpenAI (ChatGPT)", modelId: "gpt-5.5", name: "GPT-5.5",
                                thinkingLevels: ["low", "medium", "high"]),
            ReviewerModelOption(provider: "openai", providerTitle: "OpenAI (ChatGPT)", modelId: "gpt-5.5-mini", name: "GPT-5.5 mini",
                                thinkingLevels: []),
        ],
        automaticModel: "openai/gpt-5.5")

    private var toolbox: ReviewerBuilderToolbox {
        ReviewerBuilderToolbox(profiles: ReviewerProfile.defaults, catalog: catalog)
    }

    @Test func newReviewerIsNormalised() throws {
        let proposal = try toolbox.propose(ReviewerProposalInput(
            name: "  Harsh Editor ", instructions: "Be blunt about structure.\n", model: "gpt-5.5", thinkingLevel: "HIGH",
            color: "Orange", scope: "all", autoRun: true, kinds: ["structure", "spelling", "structure"], defaultKind: "structure"))
        #expect(proposal.isNew)
        #expect(proposal.changes.isEmpty)
        let draft = proposal.draft
        #expect(draft.name == "Harsh Editor")
        #expect(draft.instructions == "Be blunt about structure.")
        #expect(draft.model == "openai/gpt-5.5")
        #expect(draft.thinkingLevel == "high")
        #expect(draft.color == .orange)
        #expect(draft.scope == .all)
        #expect(draft.autoRunOnNewVersion)
        #expect(draft.kinds == [.grammar, .structure])  // "spelling" is grammar; canonical order, no repeats
        #expect(draft.defaultKind == .structure)
        #expect(!ReviewerProfile.defaults.map(\.id).contains(draft.id))
    }

    @Test func newReviewerDefaults() throws {
        let draft = try toolbox.propose(ReviewerProposalInput(name: "Gentle", instructions: "Notice feelings.", kinds: ["question", "praise"])).draft
        #expect(draft.model == "")
        #expect(draft.thinkingLevel == nil)
        #expect(draft.scope == .latest)
        #expect(!draft.autoRunOnNewVersion)
        #expect(draft.defaultKind == .question)  // the first allowed kind when insight isn't allowed
        #expect(draft.color == ReviewerColor.allCases[3 % ReviewerColor.allCases.count])
    }

    @Test func invalidFieldsAreRejectedTogether() {
        #expect(throws: ReviewToolFailure(
            "Not proposed: a new reviewer needs a name; a new reviewer needs instructions (how to review, in the second person)."
        )) {
            try toolbox.propose(ReviewerProposalInput())
        }
        #expect(throws: ReviewToolFailure(
            "Not proposed: unknown kind(s) \"nitpick\"; use: grammar, clarity, structure, insight, question, praise."
        )) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", kinds: ["grammar", "nitpick"]))
        }
        #expect(throws: ReviewToolFailure(
            "Not proposed: defaultKind must be one of the reviewer's kinds (grammar, structure), not praise."
        )) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", kinds: ["grammar", "structure"], defaultKind: "praise"))
        }
        #expect(throws: ReviewToolFailure("Not proposed: kinds needs at least one kind.")) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", kinds: []))
        }
        #expect(throws: ReviewToolFailure("Not proposed: color \"teal\" isn't one of: yellow, green, blue, pink, purple, orange.")) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", color: "teal"))
        }
        #expect(throws: ReviewToolFailure("Not proposed: scope must be \"latest\" (the version under review) or \"all\" (every version).")) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", scope: "some"))
        }
    }

    @Test func modelsAreCheckedAgainstTheCatalog() {
        #expect(toolbox.resolveModel("Automatic") == .success(""))
        #expect(toolbox.resolveModel("openai/gpt-5.5") == .success("openai/gpt-5.5"))
        #expect(toolbox.resolveModel("GPT-5.5 mini") == .success("openai/gpt-5.5-mini"))
        #expect(toolbox.resolveModel("gpt-9") == .failure(ReviewToolFailure(
            "unknown model \"gpt-9\"; call list_models for the ids, or use \"\" for Automatic")))
        #expect(toolbox.resolveModel("anthropic/claude-sonnet-5-5") == .failure(ReviewToolFailure(
            "Anthropic (Claude) isn't set up in Settings › Agents, so its models can't be used; call list_models")))
        // Thinking levels belong to the model, as in the editor.
        #expect(throws: ReviewToolFailure("Not proposed: GPT-5.5 supports thinking levels low, medium, high, not \"max\".")) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", model: "gpt-5.5", thinkingLevel: "max"))
        }
        #expect(throws: ReviewToolFailure("Not proposed: thinkingLevel needs a model: Automatic always uses the model's default.")) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", thinkingLevel: "high"))
        }
        #expect(throws: ReviewToolFailure("Not proposed: GPT-5.5 mini has no thinking levels; leave thinkingLevel out.")) {
            try toolbox.propose(ReviewerProposalInput(name: "A", instructions: "B", model: "gpt-5.5-mini", thinkingLevel: "low"))
        }
    }

    @Test func editsKeepOtherFieldsAndListChanges() throws {
        var editor = try #require(ReviewerProfile.defaults.first { $0.id == "editor" })
        editor.model = "openai/gpt-5.5"
        editor.thinkingLevel = "high"
        let toolbox = ReviewerBuilderToolbox(profiles: [editor], catalog: catalog)
        let proposal = try toolbox.propose(ReviewerProposalInput(id: "editor", model: "gpt-5.5-mini", kinds: ["grammar", "structure"]))
        #expect(!proposal.isNew)
        #expect(proposal.original == editor)
        #expect(proposal.draft.id == "editor")
        #expect(proposal.draft.instructions == editor.instructions)
        #expect(proposal.draft.thinkingLevel == nil)  // the new model has no levels
        #expect(proposal.draft.defaultKind == .grammar)  // clarity is no longer allowed
        #expect(proposal.changes == [
            ReviewerFieldChange(field: "Model", before: "GPT-5.5", after: "GPT-5.5 mini"),
            ReviewerFieldChange(field: "Thinking", before: "High", after: "Default"),
            ReviewerFieldChange(field: "Kinds", before: "Grammar, Clarity, Structure", after: "Grammar, Structure"),
            ReviewerFieldChange(field: "Default kind", before: "Clarity", after: "Grammar"),
        ])
        // By name works too; an edit that changes nothing is refused.
        #expect(try toolbox.propose(ReviewerProposalInput(id: "Editor", name: "Strict Editor")).changes
            == [ReviewerFieldChange(field: "Name", before: "Editor", after: "Strict Editor")])
        #expect(throws: ReviewToolFailure("Nothing would change: Editor already has these settings.")) {
            try toolbox.propose(ReviewerProposalInput(id: "editor", name: "Editor"))
        }
        #expect(throws: ReviewToolFailure("No reviewer \"ghost\". Leave id out to create a new reviewer, or call list_reviewers to see the ids.")) {
            try toolbox.propose(ReviewerProposalInput(id: "ghost", name: "X"))
        }
    }

    @Test func revisingAnUnsavedDraftKeepsItsId() throws {
        var toolbox = toolbox
        let first = try toolbox.propose(ReviewerProposalInput(name: "Draft", instructions: "One."))
        toolbox.drafts[first.draft.id] = first.draft
        let second = try toolbox.propose(ReviewerProposalInput(id: first.draft.id, instructions: "Two."))
        #expect(second.isNew)
        #expect(second.draft.id == first.draft.id)
        #expect(second.draft.name == "Draft")
        #expect(second.draft.instructions == "Two.")
        #expect(toolbox.summary(of: second).contains("call propose_reviewer again with id \(first.draft.id)"))
    }

    @Test func revisingAnUnsavedEditKeepsEarlierChanges() throws {
        let editor = try #require(ReviewerProfile.defaults.first { $0.id == "editor" })
        var toolbox = ReviewerBuilderToolbox(profiles: [editor], catalog: catalog)
        let first = try toolbox.propose(ReviewerProposalInput(id: "editor", instructions: "Be harsh."))
        toolbox.drafts[first.draft.id] = first.draft
        // "Keep Chatting", then a second change: the first one stays, compared with the saved reviewer.
        let second = try toolbox.propose(ReviewerProposalInput(id: "editor", color: "orange"))
        #expect(second.draft.instructions == "Be harsh.")
        #expect(second.draft.color == .orange)
        #expect(second.original == editor)
        #expect(second.changes.map(\.field).contains("Instructions"))
        // Named by name instead of id: still builds on the draft.
        let third = try toolbox.propose(ReviewerProposalInput(id: "Editor", scope: "all"))
        #expect(third.draft.instructions == "Be harsh.")
        #expect(third.draft.id == "editor")
        #expect(third.original == editor)
    }

    @Test func listings() throws {
        let reviewers = toolbox.listReviewers()
        #expect(reviewers.contains("editor · Editor · Automatic · kinds: grammar, clarity, structure"))
        #expect(try toolbox.getReviewer("mirror").contains("scope: all"))
        #expect(throws: ReviewToolFailure("No reviewer \"x\". Call list_reviewers to see the ids.")) { try toolbox.getReviewer("x") }
        let models = toolbox.listModels()
        #expect(models.contains("Automatic (model \"\"): now GPT-5.5 (openai/gpt-5.5)"))
        #expect(models.contains("- openai/gpt-5.5 · GPT-5.5 · thinking: low, medium, high"))
        #expect(ReviewerBuilderToolbox(profiles: [], catalog: .empty).listModels().hasPrefix("No provider is set up yet"))
        #expect(toolbox.listKinds().split(separator: "\n").count == AnnotationKind.allCases.count)
    }
}

@MainActor
struct ReviewerChatServiceTests {
    /// Registers the faux provider before returning, so tests can script it right away.
    private func makeService(faux: FauxProvider, profiles: [ReviewerProfile] = ReviewerProfile.defaults) async throws -> ReviewerChatService {
        let models = Models(credentials: InMemoryCredentialStore(), builtinProviders: false, catalog: nil)
        try await models.register(faux)
        let catalog = ReviewerBuilderCatalog(
            providers: ["Faux"],
            models: [ReviewerModelOption(provider: "faux", providerTitle: "Faux", modelId: "faux-1", name: "Faux One", thinkingLevels: [])],
            automaticModel: "faux/faux-1")
        return ReviewerChatService(
            makeModels: { models },
            resolveModel: { faux.model },
            loadCatalog: { catalog },
            loadProfiles: { profiles })
    }

    @Test func fauxModelProposesAReviewerAndTheDraftComesBack() async throws {
        let faux = FauxProvider()
        let service = try await makeService(faux: faux)
        let chat = ReviewerChat()
        let requests = Requests()
        try await faux.respond { messages, count in
            await requests.record(messages)
            switch count {
            case 1:
                return FauxResponse(
                    .toolCall("write", ["path": "/tmp/x", "content": "nope"]),
                    .toolCall("propose_reviewer", ["name": "Harsh Editor", "instructions": "Be blunt.", "kinds": ["structure", "nitpick"]]))
            case 2:
                return FauxResponse(.toolCall("propose_reviewer", [
                    "name": "Harsh Editor", "instructions": "Be blunt about structure.", "model": "faux/faux-1",
                    "kinds": ["grammar", "structure"], "defaultKind": "structure",
                ]))
            default:
                return .text("Here's a harsh editor that only leaves grammar and structure notes.")
            }
        }
        await service.send("A harsh editor focused on structure, only grammar and structure notes.", in: chat)
        #expect(chat.error == nil)
        #expect(!chat.isRunning)
        let proposal = try #require(chat.proposal)
        #expect(proposal.isNew)
        #expect(proposal.draft.name == "Harsh Editor")
        #expect(proposal.draft.model == "faux/faux-1")
        #expect(proposal.draft.kinds == [.grammar, .structure])
        #expect(proposal.draft.defaultKind == .structure)
        #expect(chat.drafts[proposal.draft.id] == proposal.draft)
        #expect(chat.messages.map(\.role) == [.user, .assistant])
        #expect(chat.messages.last?.text == "Here's a harsh editor that only leaves grammar and structure notes.")

        // Only the builder tools exist: the model saw the refused call and the validation error.
        let seen = await requests.all.flatMap { $0 }.compactMap { message -> String? in
            if case .toolResult(let result) = message { return result.text }
            return nil
        }
        #expect(seen.contains { $0.contains("Tool write is not available") })
        #expect(seen.contains { $0.contains("unknown kind(s) \"nitpick\"") })
        #expect(seen.contains { $0.contains("Not saved.") })
        await service.shutdown()
    }

    @Test func modelErrorsShowInlineAndRetryResends() async throws {
        let faux = FauxProvider()
        let service = try await makeService(faux: faux)
        let chat = ReviewerChat(editing: ReviewerProfile.defaults[0])
        try await faux.respond { _, count in
            count == 1 ? .error("Network connection was lost") : .text("What should change?")
        }
        await service.send("Make it gentler.", in: chat)
        #expect(chat.error == "Couldn't reach the model. Check your connection.")
        #expect(chat.messages.map(\.text) == ["Make it gentler."])
        await service.retry(in: chat)
        #expect(chat.error == nil)
        // The retried message shows once.
        #expect(chat.messages.map(\.text) == ["Make it gentler.", "What should change?"])
        await service.shutdown()
    }

    @Test func noProviderIsReported() async throws {
        let service = ReviewerChatService(
            makeModels: { throw ReviewError.notConfigured },
            resolveModel: { throw ReviewError.notConfigured },
            loadCatalog: { .empty }, loadProfiles: { [] })
        let chat = ReviewerChat()
        await service.send("Hi", in: chat)
        #expect(chat.error == ReviewError.notConfigured.localizedDescription)
    }

    private actor Requests {
        var all: [[Message]] = []
        func record(_ messages: [Message]) { all.append(messages) }
    }
}
