//
//  TemplatesSettingsView.swift
//  freewrite
//
//  Settings › Templates: the templates of the "/" menu in two columns, like Settings › Agents:
//  the list on the left (drag to reorder, +/−, ⋯), the selected one's editor on the right.
//  Edits save as you type.
//

import SwiftUI

struct TemplatesSettingsView: View {
    @AppStorage(TemplateStore.key) private var templatesJSON = ""
    @State private var selectedId: String?
    @State private var templatePendingDeletion: WritingTemplate?

    private var templates: [WritingTemplate] { TemplateStore.decode(templatesJSON) }

    private var selectedTemplate: WritingTemplate? {
        let templates = templates
        return templates.first { $0.id == selectedId } ?? templates.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsFootnote("Type / at the start of a line or after a space to insert a template; keep typing to search. Also in ⌘K › Insert Template….")
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

            HStack(alignment: .top, spacing: 12) {
                templateList
                    .frame(width: 190)
                if let template = selectedTemplate {
                    TemplateEditor(template: binding(for: template))
                        .id(template.id)
                } else {
                    ContentUnavailableView("No Templates", systemImage: "doc.text", description: Text("Add one with +."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        // The template on screen, not `selectedId` (nil until a row is clicked).
        .onChange(of: selectedTemplate?.id) { old, _ in
            if let old { fixUpName(of: old) }
        }
        .onDisappear {
            if let id = selectedTemplate?.id { fixUpName(of: id) }
        }
        .confirmationDialog(
            "Delete \(templatePendingDeletion?.displayName ?? "template")?",
            isPresented: Binding(get: { templatePendingDeletion != nil }, set: { if !$0 { templatePendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let template = templatePendingDeletion {
                    let list = templates
                    let index = list.firstIndex(where: { $0.id == template.id }) ?? 0
                    let remaining = list.filter { $0.id != template.id }
                    templatesJSON = TemplateStore.encode(remaining)
                    selectedId = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
                }
                templatePendingDeletion = nil
            }
        } message: {
            Text("Text it already inserted stays in your entries.")
        }
    }

    // MARK: List

    private var templateList: some View {
        VStack(spacing: 0) {
            // Rows are drawn like the reviewer list in Settings › Agents (inset, rounded
            // selection). A selectable plain List paints square row and selection backgrounds
            // edge to edge, over the card's rounded top corners.
            List {
                ForEach(templates) { template in
                    templateRow(template, isSelected: template.id == selectedTemplate?.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaPadding(.vertical, 5)
            Divider()
            HStack(spacing: 2) {
                Button {
                    addTemplate()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 20)
                }
                .help("Add a template")
                .accessibilityLabel("Add Template")
                Button {
                    templatePendingDeletion = selectedTemplate
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 20)
                }
                .disabled(selectedTemplate == nil)
                .help("Delete the selected template")
                .accessibilityLabel("Delete Template")
                Spacer()
                Menu {
                    Button("Move Up") { moveSelected(by: -1) }
                        .disabled(!canMoveSelected(by: -1))
                    Button("Move Down") { moveSelected(by: 1) }
                        .disabled(!canMoveSelected(by: 1))
                    Button("Duplicate") { duplicateSelected() }
                        .disabled(selectedTemplate == nil)
                    Divider()
                    Button("Restore Default Templates") {
                        templatesJSON = ""
                        selectedId = nil
                    }
                    .disabled(templatesJSON.isEmpty)
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .settingsCardBackground()
    }

    private func templateRow(_ template: WritingTemplate, isSelected: Bool) -> some View {
        Button {
            selectedId = template.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(template.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(template.preview.isEmpty ? "Empty" : template.preview)
                    .font(.system(size: 10.5))
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("templateRow-\(template.id)")
    }

    // MARK: Editing

    private func binding(for template: WritingTemplate) -> Binding<WritingTemplate> {
        Binding(
            get: { templates.first { $0.id == template.id } ?? template },
            set: { save($0) }
        )
    }

    private func save(_ template: WritingTemplate) {
        var list = templates
        if let index = list.firstIndex(where: { $0.id == template.id }) {
            list[index] = template
        } else {
            list.append(template)
        }
        templatesJSON = TemplateStore.encode(list)
    }

    private func addTemplate() {
        let template = WritingTemplate(name: "New Template", body: "")
        save(template)
        selectedId = template.id
    }

    private func duplicateSelected() {
        guard let template = selectedTemplate else { return }
        var list = templates
        let copy = WritingTemplate(name: "\(template.displayName) copy", body: template.body, font: template.font, size: template.size)
        let index = (list.firstIndex(where: { $0.id == template.id }) ?? list.count - 1) + 1
        list.insert(copy, at: index)
        templatesJSON = TemplateStore.encode(list)
        selectedId = copy.id
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = templates
        list.move(fromOffsets: source, toOffset: destination)
        templatesJSON = TemplateStore.encode(list)
    }

    private func canMoveSelected(by step: Int) -> Bool {
        guard let id = selectedTemplate?.id, let index = templates.firstIndex(where: { $0.id == id }) else { return false }
        return templates.indices.contains(index + step)
    }

    private func moveSelected(by step: Int) {
        guard canMoveSelected(by: step), let id = selectedTemplate?.id else { return }
        var list = templates
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list.swapAt(index, index + step)
        templatesJSON = TemplateStore.encode(list)
        selectedId = id
    }

    /// Names are edited live; one left empty becomes "Untitled Template" when you move on.
    private func fixUpName(of id: String) {
        guard var template = templates.first(where: { $0.id == id }) else { return }
        guard template.displayName != template.name else { return }
        template.name = template.displayName
        save(template)
    }
}

// MARK: - Template editor

/// The right column: one template's name, font, size and text, saved as you type.
private struct TemplateEditor: View {
    @Binding var template: WritingTemplate
    @AppStorage(SettingsKey.fontName) private var defaultFontName = WritingFont.defaultName
    @AppStorage(SettingsKey.fontSize) private var defaultFontSize = WritingFont.defaultSize
    @AppStorage(FavoriteFonts.key) private var favoriteFontsJSON = ""

    private static let families = NSFontManager.shared.availableFontFamilies.sorted()

    /// The text box shows the template's font and size, else the defaults for new pages.
    private var bodyFont: NSFont {
        WritingEditor.font(named: template.font ?? defaultFontName,
                           size: CGFloat(template.size ?? defaultFontSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard {
                SettingsCardRow("Name", subtitle: "What you type after / to find it") {
                    TextField("Name", text: $template.name, prompt: Text("Plan my day"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 200)
                        .accessibilityIdentifier("templateName")
                }
                SettingsCardRow("Font", subtitle: "The page switches to it when inserted") {
                    Picker("Font", selection: $template.font) {
                        Text("Keep page font").tag(String?.none)
                        Divider()
                        let favorites = FavoriteFonts.decode(favoriteFontsJSON)
                        ForEach(favorites, id: \.self) { name in
                            Text(FavoriteFonts.label(for: name)).tag(Optional(name))
                        }
                        if !favorites.isEmpty { Divider() }
                        ForEach(Self.families.filter { !favorites.contains($0) }, id: \.self) { family in
                            Text(family).tag(Optional(family))
                        }
                        // Keep a font that's no longer installed selectable.
                        if let font = template.font, !Self.families.contains(font), !favorites.contains(font) {
                            Text(FavoriteFonts.label(for: font)).tag(Optional(font))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("templateFont")
                }
                SettingsCardRow("Size") {
                    Picker("Size", selection: $template.size) {
                        Text("Keep page size").tag(Double?.none)
                        Divider()
                        ForEach(WritingFont.sizes, id: \.self) { size in
                            Text("\(Int(size)) px").tag(Optional(size))
                        }
                        if let size = template.size, !WritingFont.sizes.contains(size) {
                            Text("\(size.formatted()) px").tag(Optional(size))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("templateSize")
                }
            }

            SettingsSectionHeader("Text", detail: "Markdown, inserted as is; shown in the template's font")
            TextEditor(text: $template.body)
                .font(Font(bodyFont))
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .padding(6)
                .settingsCardBackground()
                .accessibilityIdentifier("templateBody")
            SettingsFootnote("{{date}} and {{time}} become today's date and the current time; the caret lands on {{cursor}} (else at the end).")
                .padding(.horizontal, 4)
        }
    }
}
