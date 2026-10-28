//
//  PromptsSettingsView.swift
//  freewrite
//
//  Settings › Prompts: a list of prompts (name + text), nothing else. Connected agents get them
//  as MCP prompts; "Ask an agent" copies a request naming one.
//

import SwiftUI

struct PromptsSettingsView: View {
    @AppStorage(PromptStore.key) private var promptsJSON = ""
    @State private var selectedId: String?
    @State private var pendingDeletion: AgentPrompt?

    private var prompts: [AgentPrompt] { PromptStore.decode(promptsJSON) }

    private var selected: AgentPrompt? {
        let prompts = prompts
        return prompts.first { $0.id == selectedId } ?? prompts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsFootnote("Your agents get these as prompts: in Claude Code, type /mcp__freewrite__mentor. Each one is sent with the entry open in Freewrite.")
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            HStack(alignment: .top, spacing: 12) {
                list
                    .frame(width: 180)
                if let prompt = selected {
                    editor(binding(for: prompt))
                        .id(prompt.id)
                } else {
                    ContentUnavailableView("No Prompts", systemImage: "text.bubble", description: Text("Add one with +."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .onChange(of: selected?.id) { old, _ in
            if let old { fixUpName(of: old) }
        }
        .onDisappear {
            if let id = selected?.id { fixUpName(of: id) }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "prompt")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let prompt = pendingDeletion {
                    let remaining = prompts.filter { $0.id != prompt.id }
                    promptsJSON = PromptStore.encode(remaining)
                    selectedId = remaining.first?.id
                }
                pendingDeletion = nil
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(PromptStore.named(prompts), id: \.prompt.id) { item in
                        row(item.prompt, mcpName: item.name, isSelected: item.prompt.id == selected?.id)
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 2) {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .help("Add a prompt")
                .accessibilityLabel("Add Prompt")
                Button {
                    pendingDeletion = selected
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .disabled(selected == nil)
                .help("Delete the selected prompt")
                .accessibilityLabel("Delete Prompt")
                Spacer()
                Menu {
                    Button("Restore Default Prompts") {
                        promptsJSON = ""
                        selectedId = nil
                    }
                    .disabled(promptsJSON.isEmpty)
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

    private func row(_ prompt: AgentPrompt, mcpName: String, isSelected: Bool) -> some View {
        Button {
            selectedId = prompt.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.name.isEmpty ? "Untitled Prompt" : prompt.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(mcpName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .accessibilityIdentifier("promptRow-\(prompt.id)")
    }

    // MARK: Editor

    private func editor(_ prompt: Binding<AgentPrompt>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard {
                SettingsCardRow("Name") {
                    TextField("Name", text: prompt.name, prompt: Text("Mentor"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220)
                        .accessibilityIdentifier("promptName")
                }
            }
            TextEditor(text: prompt.prompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260, maxHeight: .infinity)
                .padding(6)
                .settingsCardBackground()
                .accessibilityLabel("Prompt")
                .accessibilityIdentifier("promptText")
        }
    }

    // MARK: Saving

    private func binding(for prompt: AgentPrompt) -> Binding<AgentPrompt> {
        Binding(
            get: { prompts.first { $0.id == prompt.id } ?? prompt },
            set: { save($0) }
        )
    }

    private func save(_ prompt: AgentPrompt) {
        var list = prompts
        if let index = list.firstIndex(where: { $0.id == prompt.id }) {
            list[index] = prompt
        } else {
            list.append(prompt)
        }
        promptsJSON = PromptStore.encode(list)
    }

    private func add() {
        let prompt = AgentPrompt(name: "New Prompt", prompt: "")
        save(prompt)
        selectedId = prompt.id
    }

    /// Names are edited live; one left empty becomes "Untitled Prompt" when you move on.
    private func fixUpName(of id: String) {
        guard var prompt = prompts.first(where: { $0.id == id }) else { return }
        let trimmed = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Untitled Prompt" : trimmed
        guard name != prompt.name else { return }
        prompt.name = name
        save(prompt)
    }
}
