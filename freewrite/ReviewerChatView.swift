//
//  ReviewerChatView.swift
//  freewrite
//
//  The "New Reviewer by Chat…" sheet on Settings › Agents: messages, the draft card with
//  Save / Keep Chatting, and an input where Return sends and ⇧Return starts a new line.
//

import AppKit
import SwiftUI

struct ReviewerChatSheet: View {
    let chat: ReviewerChat
    /// Model ids → names, for the draft card.
    let modelName: (String) -> String
    /// Saves the draft through the Agents pane's store and selects it.
    let onSave: (ReviewerProfile) -> Void
    let onClose: () -> Void

    @ObservedObject private var reviews = ReviewService.shared
    @State private var draft = ""
    @State private var checkedProviders = false

    private var service: ReviewerChatService { .shared }

    private var hasProvider: Bool {
        reviews.credentialStates.values.contains { $0.isConfigured }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if checkedProviders && !hasProvider {
                noProvider
            } else {
                messageList
                Divider()
                inputBar
            }
        }
        .frame(width: 540, height: 500)
        // Closing the sheet ends the chat: whatever it was doing stops.
        .onDisappear {
            service.close(chat)
            // Closing the Settings window takes the sheet with it; don't bring a finished chat back next time.
            if ReviewerChatLauncher.shared.chat === chat { ReviewerChatLauncher.shared.chat = nil }
        }
        .task {
            await reviews.refreshCredentials()
            checkedProviders = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.editing.map { "Edit \($0.name) with Chat" } ?? "New Reviewer by Chat")
                    .font(.system(size: 13, weight: .semibold))
                Text("Sends only what you type here and your reviewer settings, never your entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var noProvider: some View {
        VStack(spacing: 12) {
            Spacer()
            ContentUnavailableView {
                Label("No Model Provider", systemImage: "key")
            } description: {
                Text("The chat runs on the same model as your reviewers. Add a Claude API key or sign in to ChatGPT first.")
            } actions: {
                Button("Set Up a Provider", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: Messages

    private var intro: String {
        if let editing = chat.editing {
            return "What should change about \(editing.name)? Its tone, what it looks for, the kinds of notes, its model…"
        }
        return "Describe the reviewer you want: what it should look for, how gentle or harsh, which kinds of notes, and a model if you care. For example: “a harsh editor focused on structure, only grammar and structure notes, on the best OpenAI model”."
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    bubble(ReviewerChatMessage(id: "intro", role: .assistant, text: intro))
                    ForEach(chat.messages) { message in
                        bubble(message)
                    }
                    if !chat.streamingText.isEmpty {
                        bubble(ReviewerChatMessage(id: "streaming", role: .assistant, text: chat.streamingText))
                    }
                    if chat.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(chat.activity ?? "Thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                    }
                    if let error = chat.error {
                        errorRow(error)
                    }
                    if let proposal = chat.proposal {
                        ReviewerProposalCard(proposal: proposal, modelName: modelName, onSave: { save(proposal) }) {
                            chat.proposal = nil
                        }
                    }
                    if let saved = chat.savedName {
                        Label("Saved “\(saved)”. It's selected in Settings › Agents.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chat.streamingText) { scrollToBottom(proxy) }
            .onChange(of: chat.proposal?.id) { scrollToBottom(proxy) }
            .onChange(of: chat.error) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func bubble(_ message: ReviewerChatMessage) -> some View {
        let isUser = message.role == .user
        let text = (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
        return HStack {
            if isUser { Spacer(minLength: 60) }
            Text(text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                )
            if !isUser { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((isUser ? "You: " : "Assistant: ") + message.text)
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if chat.lastSubmitted != nil {
                Button("Retry") {
                    Task { await service.retry(in: chat) }
                }
                .controlSize(.small)
                .disabled(chat.isRunning)
            }
        }
        .padding(10)
        .settingsCardBackground()
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatInputField(text: $draft, placeholder: chat.messages.isEmpty ? "Describe your reviewer…" : "Reply…", onSubmit: send)
                .frame(height: 54)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .settingsCardBackground()
                .accessibilityIdentifier("reviewerChatInput")
            if chat.isRunning {
                Button("Stop") { service.stop(chat) }
                    .accessibilityIdentifier("reviewerChatStop")
            } else {
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("reviewerChatSend")
            }
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isRunning else { return }
        draft = ""
        chat.proposal = nil
        Task { await service.send(text, in: chat) }
    }

    private func save(_ proposal: ReviewerProposal) {
        onSave(proposal.draft)
        chat.drafts[proposal.draft.id] = nil
        chat.proposal = nil
        chat.savedName = proposal.draft.name
    }
}

// MARK: - Draft card

/// What `propose_reviewer` drafted: the reviewer as the list shows it, its instructions, and for
/// an edit what changes.
private struct ReviewerProposalCard: View {
    let proposal: ReviewerProposal
    let modelName: (String) -> String
    let onSave: () -> Void
    let onKeepChatting: () -> Void

    private var draft: ReviewerProfile { proposal.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Color(nsColor: draft.color.nsColor))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(proposal.isNew ? "New reviewer · not saved yet" : "Changes to \(proposal.original?.name ?? draft.name) · not saved yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                detail("Model", draft.model.isEmpty ? "Automatic" : modelName(draft.model)
                       + (draft.thinkingLevel.map { " · \($0.capitalized) thinking" } ?? ""))
                detail("Reads", draft.scope == .all ? "All versions" : "The version under review")
                if draft.autoRunOnNewVersion { detail("Runs", "On each New Version") }
                HStack(spacing: 6) {
                    Text("Notes")
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    ForEach(draft.kinds) { kind in
                        HStack(spacing: 3) {
                            AnnotationKindSwatch(kind: kind, size: 8)
                            Text(kind == draft.effectiveDefaultKind ? "\(kind.title) (default)" : kind.title)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .font(.system(size: 11.5))

            if proposal.isNew {
                // In full: Save writes all of it, so all of it must be readable first.
                Text(draft.instructions)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            } else {
                changes
            }

            HStack {
                Spacer()
                Button("Keep Chatting", action: onKeepChatting)
                Button(proposal.isNew ? "Save Reviewer" : "Save Changes", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reviewerChatSave")
            }
        }
        .padding(12)
        .settingsCardBackground()
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(proposal.changes) { change in
                VStack(alignment: .leading, spacing: 3) {
                    Text(change.field)
                        .font(.system(size: 11, weight: .semibold))
                    if change.field == "Instructions" {
                        Text(change.before)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(change.after)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        HStack(spacing: 5) {
                            Text(change.before)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(change.after)
                        }
                    }
                }
                .font(.system(size: 11.5))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(change.field): \(change.before) to \(change.after)")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Input field

/// A multi-line text field: Return sends, ⇧Return (or ⌥Return) starts a new line.
private struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12.5)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.writingToolsBehavior = .none
        textView.setAccessibilityLabel("Message")
        context.coordinator.placeholder.stringValue = placeholder
        textView.addSubview(context.coordinator.placeholder)
        context.coordinator.placeholder.frame.origin = NSPoint(x: 7, y: 4)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        context.coordinator.placeholder.stringValue = placeholder
        context.coordinator.placeholder.sizeToFit()
        context.coordinator.placeholder.isHidden = !text.isEmpty
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputField
        let placeholder: NSTextField = {
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: 12.5)
            field.textColor = .placeholderTextColor
            return field
        }()

        init(_ parent: ChatInputField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            placeholder.isHidden = !textView.string.isEmpty
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Marked text (an input method) commits with Return; leave it alone.
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}
