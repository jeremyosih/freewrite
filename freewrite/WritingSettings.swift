//
//  WritingSettings.swift
//  freewrite
//
//  The look of the writing page: font and size. Settings › General holds the defaults for new
//  pages (`UserDefaults["fontName"]`, `["fontSize"]`); a page that was given its own font or size
//  keeps it in its manifest (`Entries/<base>/entry.json`, `"writing": {"font": …, "size": …}`).
//  Templates can carry them too. Pure model (unit-tested).
//

import Foundation

enum WritingFont {
    static let presets: [(label: String, name: String)] = [
        ("Lato", "Lato-Regular"),
        ("Arial", "Arial"),
        ("System", ".AppleSystemUIFont"),
        ("Serif", "Times New Roman"),
    ]
    static let defaultName = "Lato-Regular"
    static let sizes: [Double] = [16, 18, 20, 22, 24, 26]
    static let defaultSize: Double = 18

    static func displayName(for name: String) -> String {
        presets.first(where: { $0.name == name })?.label ?? name
    }

    /// The next size of `sizes` after `size`, wrapping from the largest to the smallest (the bar's
    /// "18px" button). A size that isn't in the list goes to the next bigger one.
    static func nextSize(after size: Double) -> Double {
        sizes.first(where: { $0 > size }) ?? sizes[0]
    }

    /// One step bigger (`step` 1) or smaller (-1) within `sizes`, stopping at the ends.
    static func size(_ size: Double, steppedBy step: Int) -> Double {
        let index = sizes.firstIndex(of: size)
            ?? (step > 0 ? sizes.lastIndex(where: { $0 < size }) : sizes.firstIndex(where: { $0 > size }))
            ?? sizes.firstIndex(of: defaultSize) ?? 0
        return sizes[min(max(index + step, 0), sizes.count - 1)]
    }
}

/// A page's own font and size; a nil field means the default from Settings › General.
struct WritingSettings: Codable, Equatable, Sendable {
    /// PostScript or family name (`WritingEditor.font(named:size:)` resolves either).
    var font: String?
    var size: Double?

    /// Sizes outside this range in a hand-edited file are ignored.
    static let sizeRange: ClosedRange<Double> = 8...96

    init(font: String? = nil, size: Double? = nil) {
        self.font = Self.cleanFont(font)
        self.size = Self.cleanSize(size)
    }

    /// Tolerant: a missing, mistyped or out-of-range field is just nil.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            font: (try? container.decodeIfPresent(String.self, forKey: .font)) ?? nil,
            size: (try? container.decodeIfPresent(Double.self, forKey: .size)) ?? nil
        )
    }

    var isEmpty: Bool { font == nil && size == nil }

    func resolvedFont(default defaultFont: String) -> String { font ?? defaultFont }
    func resolvedSize(default defaultSize: Double) -> Double { size ?? defaultSize }

    /// `other`'s fields where it has them, else these (a template applied to a page).
    func overlaid(with other: WritingSettings) -> WritingSettings {
        WritingSettings(font: other.font ?? font, size: other.size ?? size)
    }

    private static func cleanFont(_ font: String?) -> String? {
        guard let font = font?.trimmingCharacters(in: .whitespacesAndNewlines), !font.isEmpty else { return nil }
        return font
    }

    private static func cleanSize(_ size: Double?) -> Double? {
        guard let size, size.isFinite, sizeRange.contains(size) else { return nil }
        return size
    }
}
