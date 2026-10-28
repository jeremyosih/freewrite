//
//  Reviewers.swift
//  freewrite
//
//  Prompts (Settings › Prompts): a name and a prompt, served to connected agents over MCP.
//  Stored as JSON in `UserDefaults["prompts"]`; a missing key means the built-in defaults.
//  Also the annotation kinds' colours.
//

import AppKit
import Foundation

extension AnnotationKind {
    /// The kind's colour at full strength (legend swatches, the dot in a note's popover).
    var nsColor: NSColor {
        switch self {
        case .grammar: return .systemRed
        case .clarity: return .systemBlue
        case .structure: return .systemPurple
        case .insight: return .systemYellow
        case .question: return .systemTeal
        case .praise: return .systemGreen
        }
    }

    /// Background behind annotated text: a soft tint that keeps the text readable, a little
    /// stronger in dark mode where tints wash out. Grammar stays faint: its underline carries it.
    var highlightColor: NSColor {
        let base = nsColor
        let light: CGFloat
        let dark: CGFloat
        switch self {
        case .grammar: (light, dark) = (0.14, 0.24)
        case .insight: (light, dark) = (0.32, 0.30)
        default: (light, dark) = (0.20, 0.32)
        }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return base.withAlphaComponent(isDark ? dark : light)
        }
    }

    /// The highlight of the note whose card is hovered or active in the comment margin.
    var activeHighlightColor: NSColor {
        let base = nsColor
        let (light, dark): (CGFloat, CGFloat) = self == .grammar ? (0.30, 0.42) : (0.42, 0.55)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return base.withAlphaComponent(isDark ? dark : light)
        }
    }

    /// Grammar notes get a squiggly underline, like a spelling mark; the others only a tint.
    var underlineColor: NSColor? {
        self == .grammar ? nsColor : nil
    }
}


/// A prompt: a name and its text. Served to connected agents as MCP prompts (`/mcp__freewrite__mentor`
/// in Claude Code), copied by "Ask an agent", and used by "Continue in ChatGPT / Claude".
struct AgentPrompt: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var prompt: String

    init(id: String = UUID().uuidString, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }

    static let defaults: [AgentPrompt] = [
        AgentPrompt(
            id: "friend",
            name: "Friend",
            prompt: """
            below is my journal entry. wyt? talk through it with me like a friend. don't therpaize me and give me a whole breakdown, don't repeat my thoughts with headings. really take all of this, and tell me back stuff truly as if you're an old homie.

            Keep it casual, dont say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with markdown headings if needed.

            do not just go through every single thing i say, and say it back to me. you need to proccess everythikng is say, make connections i don't see it, and deliver it all back to me as a story that makes me feel what you think i wanna feel. thats what the best therapists do.

            ideally, you're style/tone should sound like the user themselves. it's as if the user is hearing their own tone but it should still feel different, because you have different things to say and don't just repeat back they say.

            else, start by saying, "hey, thanks for showing me this. my thoughts:"

            my entry:
            """
        ),
        AgentPrompt(
            id: "mentor",
            name: "Mentor",
            prompt: """
            Take a look at my journal entry below. I'd like you to analyze it and respond with deep insight that feels personal, not clinical.
            Imagine you're not just a friend, but a mentor who truly gets both my tech background and my psychological patterns. I want you to uncover the deeper meaning and emotional undercurrents behind my scattered thoughts.
            Keep it casual, dont say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with markdown headings if needed.
            Use vivid metaphors and powerful imagery to help me see what I'm really building. Organize your thoughts with meaningful headings that create a narrative journey through my ideas.
            Don't just validate my thoughts - reframe them in a way that shows me what I'm really seeking beneath the surface. Go beyond the product concepts to the emotional core of what I'm trying to solve.
            Be willing to be profound and philosophical without sounding like you're giving therapy. I want someone who can see the patterns I can't see myself and articulate them in a way that feels like an epiphany.
            Start with 'hey, thanks for showing me this. my thoughts:' and then use markdown headings to structure your response.

            Here's my journal entry:
            """
        ),
        AgentPrompt(
            id: "editor",
            name: "Editor",
            prompt: """
            Read this as a thoughtful editor helping a raw freewrite become clearer, without sanding off its \
            voice. Point to the sentences where the real idea is (often buried mid-paragraph), passages that \
            repeat themselves, places where the thread jumps and the reader gets lost, and vague words that \
            hide a sharper one. Suggest the move ("this could open the piece", "cut the first half of this \
            paragraph"), never the rewrite. Quote each passage you mean. Then list real spelling and grammar \
            mistakes, one per line; skip the loose, spoken style of stream-of-consciousness writing, which is \
            not a mistake.

            My writing:
            """
        ),
    ]
}

enum PromptStore {
    /// A missing key means the built-in defaults.
    static let key = "prompts"

    static func decode(_ json: String) -> [AgentPrompt] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let prompts = try? JSONDecoder().decode([AgentPrompt].self, from: data) else {
            return AgentPrompt.defaults
        }
        return prompts
    }

    static func encode(_ prompts: [AgentPrompt]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(prompts) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func load(_ defaults: UserDefaults = .standard) -> [AgentPrompt] {
        decode(defaults.string(forKey: key) ?? "")
    }

    /// MCP names: the name as a slug ("mentor", "my-editor"), unique within the list.
    static func named(_ prompts: [AgentPrompt]) -> [(name: String, prompt: AgentPrompt)] {
        var used = Set<String>()
        return prompts.map { prompt in
            var name = slug(prompt.name)
            if name.isEmpty { name = "prompt" }
            var candidate = name
            var n = 2
            while used.contains(candidate) { candidate = "\(name)-\(n)"; n += 1 }
            used.insert(candidate)
            return (candidate, prompt)
        }
    }

    static func slug(_ name: String) -> String {
        name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
    }
}

/// A chat site on the web, for "Continue in ChatGPT / Claude".
enum ChatSite: String, CaseIterable, Identifiable, Sendable {
    case chatGPT, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    var base: String {
        switch self {
        case .chatGPT: return "https://chatgpt.com/?q="
        case .claude: return "https://claude.ai/new?q="
        }
    }

    var home: URL {
        switch self {
        case .chatGPT: return URL(string: "https://chatgpt.com/")!
        case .claude: return URL(string: "https://claude.ai/new")!
        }
    }
}

/// Opens a prompt and the writing in ChatGPT or Claude on the web. Nothing is sent from the
/// app: the browser opens the link.
enum ExternalChat {
    /// Links longer than this fail in some browsers; the prompt is copied instead.
    static let maxURLLength = 6000

    static func prompt(_ prompt: AgentPrompt, text: String) -> String {
        prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chat site with `prompt` prefilled.
    static func url(for site: ChatSite, prompt: String) -> URL? {
        // Query values: escape the characters that would end or split the parameter.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?")
        guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: site.base + encoded)
    }
}

/// How a note looks, from what the agent chose: its colour (else the label's: a fixed kind's
/// colour, or a stable colour picked from the label), its label, and tint or squiggle.
struct NoteStyle: Equatable {
    let label: String
    let color: NSColor
    let isSquiggle: Bool

    static let namedColors: [String: NSColor] = [
        "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen,
        "mint": .systemMint, "teal": .systemTeal, "cyan": .systemCyan, "blue": .systemBlue,
        "indigo": .systemIndigo, "purple": .systemPurple, "pink": .systemPink, "brown": .systemBrown,
        "gray": .systemGray, "grey": .systemGray,
    ]

    /// Labels without a colour of their own cycle through these, by a stable hash of the label.
    private static let palette: [NSColor] = [.systemYellow, .systemBlue, .systemPurple, .systemTeal, .systemGreen, .systemOrange, .systemPink, .systemIndigo, .systemMint]

    init(_ note: Annotation) {
        let raw = note.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = AnnotationKind(rawValue: raw.lowercased())
        label = raw.isEmpty ? "Note" : raw.prefix(1).uppercased() + raw.dropFirst()
        color = note.color.flatMap(Self.parse)
            ?? known?.nsColor
            ?? Self.palette[Self.stableHash(raw.lowercased()) % Self.palette.count]
        switch note.style?.lowercased() {
        case "squiggle", "underline", "wavy": isSquiggle = true
        case "highlight", "tint": isSquiggle = false
        default: isSquiggle = known == .grammar
        }
    }

    /// "#RRGGBB", "#RGB" or a colour name.
    static func parse(_ value: String) -> NSColor? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let named = namedColors[value] { return named }
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                       blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }

    private static func stableHash(_ text: String) -> Int {
        var hash: UInt32 = 5381
        for scalar in text.unicodeScalars { hash = (hash &* 33) &+ scalar.value }
        return Int(hash % 1_000_003)
    }

    /// The tint behind the passage (faint under a squiggle, which carries it).
    var highlightColor: NSColor { tint(light: isSquiggle ? 0.12 : 0.24, dark: isSquiggle ? 0.22 : 0.32) }
    /// The tint while the note's card is hovered or active.
    var activeHighlightColor: NSColor { tint(light: isSquiggle ? 0.30 : 0.42, dark: isSquiggle ? 0.42 : 0.55) }
    var underlineColor: NSColor? { isSquiggle ? color : nil }

    private func tint(light: CGFloat, dark: CGFloat) -> NSColor {
        let base = color
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return base.withAlphaComponent(isDark ? dark : light)
        }
    }
}

extension Annotation {
    var noteStyle: NoteStyle { NoteStyle(self) }
}
