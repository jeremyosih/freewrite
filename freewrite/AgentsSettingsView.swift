//
//  AgentsSettingsView.swift
//  freewrite
//
//  Settings › Agents: model providers (Claude API key, ChatGPT sign-in or OpenAI key) and
//  reviewer profiles.
//

import PiDurableKit
import SwiftUI

struct AgentsSettingsView: View {
    @ObservedObject private var reviews = ReviewService.shared
    @AppStorage(ReviewerStore.key) private var reviewersJSON = ""

    @State private var keyDrafts: [ReviewProvider: String] = [:]
    @State private var providerMessages: [ReviewProvider: String] = [:]
    @State private var signingIn = false
    @State private var showingOpenAIKey = false
    @State private var models: [ReviewProvider: [ModelInfo]] = [:]
    @State private var editing: ReviewerProfile?
    @State private var isNewProfile = false
    @State private var profilePendingDeletion: ReviewerProfile?

    private var profiles: [ReviewerProfile] { ReviewerStore.decode(reviewersJSON) }

    var body: some View {
        Form {
            Section {
                anthropicRow
                openAIRow
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys and sign-ins are kept in your Mac's Keychain and only sent to the provider. Builds without a signing team (local development builds) may not be able to use the Keychain; you'll see an error here if so.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
                HStack {
                    Button("Add Reviewer…") {
                        isNewProfile = true
                        editing = ReviewerProfile(name: "", instructions: "", color: ReviewerColor.allCases[profiles.count % ReviewerColor.allCases.count])
                    }
                    Spacer()
                    Button("Restore Defaults") {
                        reviewersJSON = ""
                    }
                    .disabled(reviewersJSON.isEmpty)
                }
            } header: {
                Text("Reviewers")
            } footer: {
                Text("Run a reviewer on the entry you're reading with Review with… (\(ShortcutStore.shortcut(for: .reviewEntry, in: UserDefaults.standard.string(forKey: SettingsKey.shortcuts) ?? "{}")?.displayString ?? "⇧⌘E")) or the ✦ in the bottom bar. Reviewers leave highlighted notes; hover to read, right-click to dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await reviews.refreshCredentials()
            await loadModels()
        }
        .sheet(item: $editing) { profile in
            ReviewerEditor(profile: profile, isNew: isNewProfile, models: models) { saved in
                save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog(
            "Delete \(profilePendingDeletion?.name ?? "reviewer")?",
            isPresented: Binding(get: { profilePendingDeletion != nil }, set: { if !$0 { profilePendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = profilePendingDeletion {
                    reviewersJSON = ReviewerStore.encode(profiles.filter { $0.id != profile.id })
                }
                profilePendingDeletion = nil
            }
        } message: {
            Text("Notes it already left stay on your entries.")
        }
    }

    // MARK: Providers

    private var anthropicRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerHeader(.anthropic)
            keyField(.anthropic)
            if let message = providerMessages[.anthropic] {
                messageText(message)
            }
            Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var openAIRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerHeader(.openAI)
            HStack {
                if case .signedIn = reviews.credentialStates[.openAI] {
                    Button("Sign Out") { remove(.openAI) }
                } else {
                    Button(signingIn ? "Waiting for the browser…" : "Sign in with ChatGPT") { signIn() }
                        .disabled(signingIn)
                    if signingIn {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer()
                Button(showingOpenAIKey ? "Hide API Key" : "Use an API Key Instead") {
                    showingOpenAIKey.toggle()
                }
                .buttonStyle(.link)
            }
            if showingOpenAIKey {
                keyField(.openAI)
            }
            if let message = providerMessages[.openAI] {
                messageText(message)
            }
        }
        .padding(.vertical, 2)
    }

    private func providerHeader(_ provider: ReviewProvider) -> some View {
        HStack {
            Text(provider.title)
                .font(.headline)
            Spacer()
            switch reviews.credentialStates[provider] ?? ProviderCredentialState.none {
            case .none:
                Label("Not set up", systemImage: "circle")
                    .foregroundStyle(.secondary)
            case .apiKey(let masked):
                Label("API key \(masked)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .signedIn:
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private func keyField(_ provider: ReviewProvider) -> some View {
        HStack {
            SecureField("API key", text: Binding(
                get: { keyDrafts[provider] ?? "" },
                set: { keyDrafts[provider] = $0 }
            ), prompt: Text(provider.keyPlaceholder))
            .labelsHidden()
            .onSubmit { saveKey(provider) }
            Button("Save") { saveKey(provider) }
                .disabled((keyDrafts[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            if case .apiKey = reviews.credentialStates[provider] {
                Button("Remove Key") { remove(provider) }
            }
        }
    }

    private func messageText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveKey(_ provider: ReviewProvider) {
        let key = keyDrafts[provider] ?? ""
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            do {
                try await reviews.saveAPIKey(key, for: provider)
                keyDrafts[provider] = ""
                providerMessages[provider] = nil
            } catch {
                providerMessages[provider] = error.localizedDescription
            }
        }
    }

    private func remove(_ provider: ReviewProvider) {
        Task {
            do {
                try await reviews.removeCredential(for: provider)
                providerMessages[provider] = nil
            } catch {
                providerMessages[provider] = error.localizedDescription
            }
        }
    }

    private func signIn() {
        signingIn = true
        providerMessages[.openAI] = nil
        Task {
            defer { signingIn = false }
            do {
                try await reviews.signIn(to: .openAI)
            } catch is CancellationError {
                // Closed the sign-in page.
            } catch PiDurableError.cancelled {
                // Same, reported by the runtime.
            } catch {
                providerMessages[.openAI] = "Sign-in failed: \(FreewriteCredentialStore.describe(error))"
            }
        }
    }

    private func loadModels() async {
        for provider in ReviewProvider.allCases where models[provider] == nil {
            models[provider] = await reviews.availableModels(for: provider)
                .filter { !$0.modelId.contains("realtime") }
        }
    }

    // MARK: Profiles

    private func profileRow(_ profile: ReviewerProfile) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: profile.color.nsColor))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(modelDescription(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit…") {
                isNewProfile = false
                editing = profile
            }
            Button {
                profilePendingDeletion = profile
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete \(profile.name)")
        }
    }

    private func modelDescription(_ profile: ReviewerProfile) -> String {
        var parts = [profile.model.isEmpty ? "Automatic model" : modelName(profile.model)]
        if let level = profile.thinkingLevel { parts.append("thinking \(level)") }
        parts.append(profile.scope == .all ? "all versions" : "one version")
        if profile.autoRunOnNewVersion { parts.append("runs on New Version") }
        return parts.joined(separator: " · ")
    }

    private func modelName(_ reference: String) -> String {
        for list in models.values {
            if let model = list.first(where: { $0.id == reference }) { return model.name }
        }
        return reference
    }

    private func save(_ profile: ReviewerProfile) {
        var list = profiles
        if let index = list.firstIndex(where: { $0.id == profile.id }) {
            list[index] = profile
        } else {
            list.append(profile)
        }
        reviewersJSON = ReviewerStore.encode(list)
    }
}

// MARK: - Profile editor

private struct ReviewerEditor: View {
    @State var profile: ReviewerProfile
    let isNew: Bool
    let models: [ReviewProvider: [ModelInfo]]
    let onSave: (ReviewerProfile) -> Void
    let onCancel: () -> Void

    private var selectedModel: ModelInfo? {
        models.values.lazy.compactMap { $0.first(where: { $0.id == profile.model }) }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $profile.name, prompt: Text("Mirror"))

                Picker("Model", selection: $profile.model) {
                    Text("Automatic").tag("")
                    ForEach(ReviewProvider.allCases) { provider in
                        Section(provider.title) {
                            ForEach(models[provider] ?? []) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                    }
                    if !profile.model.isEmpty && selectedModel == nil {
                        Text(profile.model).tag(profile.model)
                    }
                }

                Picker("Thinking", selection: Binding(
                    get: { profile.thinkingLevel ?? "" },
                    set: { profile.thinkingLevel = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default").tag("")
                    ForEach(thinkingLevels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
                .disabled(thinkingLevels.isEmpty)

                Picker("Highlight", selection: $profile.color) {
                    ForEach(ReviewerColor.allCases) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(nsColor: color.nsColor))
                        }
                        .tag(color)
                    }
                }

                Picker("Reads", selection: $profile.scope) {
                    Text("The version under review").tag(ReviewerProfile.Scope.latest)
                    Text("All versions").tag(ReviewerProfile.Scope.all)
                }

                Toggle("Run automatically on New Version", isOn: $profile.autoRunOnNewVersion)

                Section {
                    TextEditor(text: $profile.instructions)
                        .font(.system(size: 12))
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("How to review")
                } footer: {
                    Text("Freewrite already tells every reviewer to quote exactly, annotate rather than rewrite, and be kind. Describe what this one should look for.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var saved = profile
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
    }

    /// The chosen model's levels (without "off"), or none for Automatic.
    private var thinkingLevels: [String] {
        (selectedModel?.thinkingLevels ?? []).map(\.rawValue).filter { $0 != "off" }
    }
}
