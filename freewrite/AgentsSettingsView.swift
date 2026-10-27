//
//  AgentsSettingsView.swift
//  freewrite
//
//  Settings › Agents: model providers (Claude API key, ChatGPT sign-in or OpenAI key) on top,
//  then reviewer profiles in two columns: the list on the left, the selected one's editor on the right.
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
    @State private var selectedId: String?
    @State private var profilePendingDeletion: ReviewerProfile?

    private var profiles: [ReviewerProfile] { ReviewerStore.decode(reviewersJSON) }

    private var selectedProfile: ReviewerProfile? {
        let profiles = profiles
        return profiles.first { $0.id == selectedId } ?? profiles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard {
                anthropicRow
                openAIRow
                if showingOpenAIKey, !(reviews.credentialStates[.openAI]?.isConfigured ?? false) {
                    SettingsCardRow("OpenAI API key", subtitle: "Used instead of a ChatGPT sign-in") {
                        keyField(.openAI)
                    }
                }
                ForEach(ReviewProvider.allCases.filter { providerMessages[$0] != nil }) { provider in
                    messageText(providerMessages[provider] ?? "")
                }
            }
            SettingsFootnote("Reviews are the one feature that sends your writing off this Mac: the entry's versions go to the provider you choose, under their privacy terms, only when you start a review or turn on auto-run. Keys and sign-ins stay in your Mac's Keychain.")
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

            HStack(alignment: .top, spacing: 12) {
                reviewerList
                    .frame(width: 190)
                if let profile = selectedProfile {
                    ReviewerEditor(profile: binding(for: profile), models: models)
                        .id(profile.id)
                } else {
                    ContentUnavailableView("No Reviewers", systemImage: "sparkles", description: Text("Add one with +."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .task {
            await reviews.refreshCredentials()
            await loadModels()
        }
        // The reviewer on screen, not `selectedId` (nil until a row is clicked, while the first
        // reviewer is already shown and editable).
        .onChange(of: selectedProfile?.id) { old, _ in
            if let old { fixUpName(of: old) }
        }
        .onDisappear {
            if let id = selectedProfile?.id { fixUpName(of: id) }
        }
        .confirmationDialog(
            "Delete \(profilePendingDeletion?.name ?? "reviewer")?",
            isPresented: Binding(get: { profilePendingDeletion != nil }, set: { if !$0 { profilePendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let profile = profilePendingDeletion {
                    let remaining = profiles.filter { $0.id != profile.id }
                    reviewersJSON = ReviewerStore.encode(remaining)
                    selectedId = remaining.first?.id
                }
                profilePendingDeletion = nil
            }
        } message: {
            Text("Notes it already left stay on your entries.")
        }
    }

    // MARK: Providers

    private var anthropicRow: some View {
        SettingsCardRow {
            Text(ReviewProvider.anthropic.title)
            HStack(spacing: 6) {
                providerStatus(.anthropic)
                Link("Get an API key", destination: URL(string: "https://platform.claude.com/settings/keys")!)
            }
        } control: {
            if case .apiKey = reviews.credentialStates[.anthropic] {
                Button("Remove Key") { remove(.anthropic) }
            } else {
                keyField(.anthropic)
            }
        }
    }

    private var openAIRow: some View {
        SettingsCardRow {
            Text(ReviewProvider.openAI.title)
            providerStatus(.openAI)
        } control: {
            switch reviews.credentialStates[.openAI] ?? ProviderCredentialState.none {
            case .signedIn:
                Button("Sign Out") { remove(.openAI) }
            case .apiKey:
                Button("Remove Key") { remove(.openAI) }
            default:
                HStack(spacing: 8) {
                    if signingIn {
                        ProgressView().controlSize(.small)
                    }
                    Button(signingIn ? "Waiting for the browser…" : "Sign in with ChatGPT") { signIn() }
                        .disabled(signingIn)
                    Button(showingOpenAIKey ? "Hide Key" : "API Key…") { showingOpenAIKey.toggle() }
                }
            }
        }
    }

    @ViewBuilder
    private func providerStatus(_ provider: ReviewProvider) -> some View {
        Group {
            switch reviews.credentialStates[provider] ?? ProviderCredentialState.none {
            case .none:
                Text("Not set up")
            case .apiKey(let masked):
                Label("API key \(masked)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .signedIn:
                Label("Signed in with ChatGPT", systemImage: "checkmark.circle.fill")
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
        HStack(spacing: 6) {
            SecureField("API key", text: Binding(
                get: { keyDrafts[provider] ?? "" },
                set: { keyDrafts[provider] = $0 }
            ), prompt: Text(provider.keyPlaceholder))
            .labelsHidden()
            .frame(width: 170)
            .onSubmit { saveKey(provider) }
            Button("Save") { saveKey(provider) }
                .disabled((keyDrafts[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func messageText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveKey(_ provider: ReviewProvider) {
        let key = keyDrafts[provider] ?? ""
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            do {
                try await reviews.saveAPIKey(key, for: provider)
                keyDrafts[provider] = ""
                providerMessages[provider] = nil
                if provider == .openAI { showingOpenAIKey = false }
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

    // MARK: Reviewer list

    private var reviewerList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(profiles) { profile in
                        reviewerRow(profile, isSelected: profile.id == selectedProfile?.id)
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 2) {
                Button {
                    addReviewer()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 20)
                }
                .help("Add a reviewer")
                .accessibilityLabel("Add Reviewer")
                Button {
                    profilePendingDeletion = selectedProfile
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 20)
                }
                .disabled(selectedProfile == nil)
                .help("Delete the selected reviewer")
                .accessibilityLabel("Delete Reviewer")
                Spacer()
                Menu {
                    Button("Restore Default Reviewers") {
                        reviewersJSON = ""
                        selectedId = nil
                    }
                    .disabled(reviewersJSON.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .settingsCardBackground()
    }

    private func reviewerRow(_ profile: ReviewerProfile, isSelected: Bool) -> some View {
        Button {
            selectedId = profile.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Color(nsColor: profile.color.nsColor))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name.isEmpty ? "Untitled Reviewer" : profile.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(modelName(profile))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        ForEach(profile.kinds) { kind in
                            AnnotationKindSwatch(kind: kind, size: 7)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Notes: " + profile.kinds.map(\.title).joined(separator: ", "))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("reviewerRow-\(profile.id)")
    }

    private func modelName(_ profile: ReviewerProfile) -> String {
        guard !profile.model.isEmpty else { return "Automatic model" }
        for list in models.values {
            if let model = list.first(where: { $0.id == profile.model }) { return model.name }
        }
        return profile.model
    }

    // MARK: Editing

    private func binding(for profile: ReviewerProfile) -> Binding<ReviewerProfile> {
        Binding(
            get: { profiles.first { $0.id == profile.id } ?? profile },
            set: { save($0) }
        )
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

    private func addReviewer() {
        let profile = ReviewerProfile(
            name: "New Reviewer", instructions: "",
            color: ReviewerColor.allCases[profiles.count % ReviewerColor.allCases.count])
        save(profile)
        selectedId = profile.id
    }

    /// Names are edited live; one left empty becomes "Untitled Reviewer" when you move on.
    private func fixUpName(of id: String) {
        guard var profile = profiles.first(where: { $0.id == id }) else { return }
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Untitled Reviewer" : trimmed
        guard name != profile.name else { return }
        profile.name = name
        save(profile)
    }
}

// MARK: - Reviewer editor

/// The right column: everything about one reviewer, saved as you change it.
private struct ReviewerEditor: View {
    @Binding var profile: ReviewerProfile
    let models: [ReviewProvider: [ModelInfo]]

    private var selectedModel: ModelInfo? {
        models.values.lazy.compactMap { $0.first(where: { $0.id == profile.model }) }.first
    }

    /// The chosen model's levels (without "off"), or none for Automatic.
    private var thinkingLevels: [String] {
        (selectedModel?.thinkingLevels ?? []).map(\.rawValue).filter { $0 != "off" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsCard {
                    SettingsCardRow("Name") {
                        TextField("Name", text: $profile.name, prompt: Text("Mirror"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 170)
                            .accessibilityIdentifier("reviewerName")
                    }
                    SettingsCardRow("Colour", subtitle: "Its dot in menus and lists") {
                        Picker("Colour", selection: $profile.color) {
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
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                SettingsSectionHeader("How to review", detail: "What this reviewer looks for")
                TextEditor(text: $profile.instructions)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 130)
                    .padding(6)
                    .settingsCardBackground()
                    .accessibilityIdentifier("reviewerInstructions")
                SettingsFootnote("Freewrite already tells every reviewer to quote exactly, annotate rather than rewrite, and be kind.")
                    .padding(.horizontal, 4)

                SettingsSectionHeader("Model")
                SettingsCard {
                    SettingsCardRow("Model", subtitle: profile.model.isEmpty ? "Claude if set up, else ChatGPT" : nil) {
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
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    }
                    SettingsCardRow("Thinking") {
                        Picker("Thinking", selection: Binding(
                            get: { profile.thinkingLevel ?? "" },
                            set: { profile.thinkingLevel = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("Default").tag("")
                            ForEach(thinkingLevels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(thinkingLevels.isEmpty)
                    }
                    SettingsCardRow("Reads") {
                        Picker("Reads", selection: $profile.scope) {
                            Text("The version under review").tag(ReviewerProfile.Scope.latest)
                            Text("All versions").tag(ReviewerProfile.Scope.all)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsCardRow("Run on New Version", subtitle: "Reviews each version you seal") {
                        Toggle("Run automatically on New Version", isOn: $profile.autoRunOnNewVersion)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                SettingsSectionHeader("Kinds of notes", detail: "Each kind has its own highlight")
                SettingsCard {
                    ForEach(AnnotationKind.allCases) { kind in
                        SettingsCardRow {
                            HStack(spacing: 7) {
                                AnnotationKindSample(kind: kind)
                            }
                            Text(kind.guidance.prefix(1).uppercased() + kind.guidance.dropFirst())
                        } control: {
                            Toggle(kind.title, isOn: kindBinding(kind))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(profile.kinds == [kind])
                        }
                    }
                    SettingsCardRow("Default kind", subtitle: "When the model doesn't pick one") {
                        Picker("Default kind", selection: Binding(
                            get: { profile.effectiveDefaultKind },
                            set: { profile.defaultKind = $0 }
                        )) {
                            ForEach(profile.kinds) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
    }

    private func kindBinding(_ kind: AnnotationKind) -> Binding<Bool> {
        Binding(
            get: { profile.kinds.contains(kind) },
            set: { isOn in
                var kinds = profile.kinds.filter { $0 != kind }
                if isOn { kinds.append(kind) }
                guard !kinds.isEmpty else { return }
                profile.kinds = kinds
            }
        )
    }
}

// MARK: - Kinds

/// A small rounded swatch in a kind's colour.
struct AnnotationKindSwatch: View {
    let kind: AnnotationKind
    var size: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Color(nsColor: kind.nsColor))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The kind's name drawn the way the editor highlights it: tinted, and with a squiggle for grammar.
struct AnnotationKindSample: View {
    let kind: AnnotationKind

    var body: some View {
        Text(kind.title)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: kind.highlightColor))
            )
            .overlay(alignment: .bottom) {
                if let underline = kind.underlineColor {
                    Wave()
                        .stroke(Color(nsColor: underline), lineWidth: 1.1)
                        .frame(height: 3)
                        .padding(.horizontal, 4)
                        .offset(y: 1)
                }
            }
            .accessibilityLabel("\(kind.title) notes")
    }

    /// The editor's squiggle (`UnderlineOverlayView`) at sample size.
    private struct Wave: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                let step: CGFloat = 2
                var x = rect.minX
                var up = true
                path.move(to: CGPoint(x: x, y: rect.midY))
                while x < rect.maxX {
                    let next = min(x + step, rect.maxX)
                    path.addQuadCurve(to: CGPoint(x: next, y: rect.midY),
                                      control: CGPoint(x: (x + next) / 2, y: up ? rect.minY : rect.maxY))
                    x = next
                    up.toggle()
                }
            }
        }
    }
}

/// Which colour means what: every kind with its swatch, and how many notes of each are on the
/// version when `notes` isn't empty. Used in the Review menu.
struct AnnotationKindLegend: View {
    var notes: [Annotation] = []

    private var counts: [AnnotationKind: Int] {
        notes.reduce(into: [:]) { $0[$1.resolvedKind, default: 0] += 1 }
    }

    var body: some View {
        let counts = counts
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                  alignment: .leading, spacing: 5) {
            ForEach(AnnotationKind.allCases) { kind in
                HStack(spacing: 5) {
                    AnnotationKindSwatch(kind: kind, size: 8)
                    Text(counts[kind].map { "\(kind.title) \($0)" } ?? kind.title)
                        .font(.system(size: 11))
                        .opacity(notes.isEmpty || counts[kind] != nil ? 0.8 : 0.4)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Highlight colours")
    }
}
