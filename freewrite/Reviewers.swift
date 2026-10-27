//
//  Reviewers.swift
//  freewrite
//
//  Reviewer profiles (Settings › Agents): who reviews an entry, how, and with which model.
//  Stored as JSON in `UserDefaults["reviewers"]`; a missing key means the built-in defaults.
//

import AppKit
import Foundation

enum ReviewerColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow, green, blue, pink, purple, orange

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .orange: return .systemOrange
        }
    }

    /// Background behind annotated text: light enough to read through in both themes.
    var highlightColor: NSColor { nsColor.withAlphaComponent(0.28) }
}

struct ReviewerProfile: Codable, Equatable, Identifiable, Sendable {
    enum Scope: String, Codable, CaseIterable, Sendable {
        /// Only the version being reviewed (it may still look at others).
        case latest
        /// Every version, to comment on how the writing changed.
        case all
    }

    var id: String
    var name: String
    /// How to review, in the profile owner's words.
    var instructions: String
    /// "provider/modelId", or empty for the first signed-in provider's default model.
    var model: String
    /// A PiDurableKit thinking level ("low", "high", …), or nil for the model's default.
    var thinkingLevel: String?
    var color: ReviewerColor
    var scope: Scope
    var autoRunOnNewVersion: Bool

    init(
        id: String = UUID().uuidString, name: String, instructions: String, model: String = "",
        thinkingLevel: String? = nil, color: ReviewerColor, scope: Scope = .latest, autoRunOnNewVersion: Bool = false
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.color = color
        self.scope = scope
        self.autoRunOnNewVersion = autoRunOnNewVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        color = (try? container.decode(ReviewerColor.self, forKey: .color)) ?? .yellow
        scope = (try? container.decode(Scope.self, forKey: .scope)) ?? .latest
        autoRunOnNewVersion = try container.decodeIfPresent(Bool.self, forKey: .autoRunOnNewVersion) ?? false
    }

    static let defaults: [ReviewerProfile] = [
        ReviewerProfile(
            id: "mirror",
            name: "Mirror",
            instructions: """
            Reflect the writer back to themselves. Notice the feelings underneath the words (named or not), \
            the patterns and phrases that keep coming back, contradictions, and what gets circled but never \
            said outright. Name what you see plainly and warmly, the way a perceptive friend would ("You \
            mention being tired three times, each time right after talking about work."). Don't diagnose, \
            judge or give advice. Prefer a few precise observations over many vague ones, and anchor each to \
            the exact words that show it. When several versions exist, point out what shifted between them.
            """,
            color: .yellow,
            scope: .all
        ),
        ReviewerProfile(
            id: "editor",
            name: "Editor",
            instructions: """
            Read as a thoughtful editor helping a raw freewrite become clearer, without sanding off its \
            voice. Point to the sentences where the real idea is (often buried mid-paragraph), passages that \
            repeat themselves, places where the thread jumps and the reader gets lost, and vague words that \
            hide a sharper one. Suggest the move ("this could open the piece", "cut the first half of this \
            paragraph"), never the rewrite. Ignore typos and grammar unless they change the meaning: this is \
            stream-of-consciousness writing. At most one note per paragraph.
            """,
            color: .blue
        ),
        ReviewerProfile(
            id: "coach",
            name: "Coach",
            instructions: """
            Help the writer go one step deeper. For the moments that carry the most energy (a decision being \
            avoided, a wish said in passing, a worry, a small win), ask one open, specific question that they \
            could write about next time ("What would 'enough' look like here?"). Questions only, no advice, no \
            praise padding. Keep each to one or two sentences, and pick the three to five moments that matter \
            most rather than covering everything.
            """,
            color: .green,
            autoRunOnNewVersion: false
        ),
    ]
}

enum ReviewerStore {
    static let key = "reviewers"

    static func decode(_ json: String) -> [ReviewerProfile] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([ReviewerProfile].self, from: data) else {
            return ReviewerProfile.defaults
        }
        return profiles
    }

    static func encode(_ profiles: [ReviewerProfile]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func load(_ defaults: UserDefaults = .standard) -> [ReviewerProfile] {
        decode(defaults.string(forKey: key) ?? "")
    }

    static func profile(id: String, _ defaults: UserDefaults = .standard) -> ReviewerProfile? {
        load(defaults).first { $0.id == id }
    }
}
