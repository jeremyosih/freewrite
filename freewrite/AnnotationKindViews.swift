//
//  AnnotationKindViews.swift
//  freewrite
//
//  Kind colours in SwiftUI: a swatch, and the legend shown in the Review menu.
//

import SwiftUI

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

/// Which colour means what on this version: each label the notes use, in its colour, with a count.
struct AnnotationKindLegend: View {
    var notes: [Annotation] = []

    private var groups: [(style: NoteStyle, count: Int)] {
        var order: [String] = []
        var groups: [String: (NoteStyle, Int)] = [:]
        for note in notes {
            let style = note.noteStyle
            let key = style.label.lowercased()
            if groups[key] == nil { order.append(key); groups[key] = (style, 0) }
            groups[key]?.1 += 1
        }
        return order.compactMap { groups[$0] }.map { (style: $0.0, count: $0.1) }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                  alignment: .leading, spacing: 5) {
            ForEach(groups, id: \.style.label) { group in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                        .fill(Color(nsColor: group.style.color))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("\(group.style.label) \(group.count)")
                        .font(.system(size: 11))
                        .opacity(0.8)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Highlight colours")
    }
}
