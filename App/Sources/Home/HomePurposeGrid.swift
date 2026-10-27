import SwiftUI
import VisionOneKit

/// "What are you making?": one card per `Purpose`, then "Just record".
/// The chosen card gets an ink border. An empty id means just record.
struct HomePurposeGrid: View {
    @Binding var selectedID: String
    /// Two columns on a narrow pane, three otherwise (design v2).
    let columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
                  alignment: .leading, spacing: 12) {
            ForEach(Purpose.all) { purpose in
                HomePurposeCard(title: purpose.title, blurb: purpose.blurb, formats: purpose.formats,
                                isSelected: selectedID == purpose.id) {
                    selectedID = purpose.id
                }
            }
            HomePurposeCard(title: "Just record", blurb: "Decide later", formats: ["square", "vertical"],
                            isSelected: selectedID.isEmpty) {
                selectedID = ""
            }
        }
    }
}

/// Format shapes, bold title, muted blurb.
private struct HomePurposeCard: View {
    let title: String
    let blurb: String
    let formats: [String]
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HomeFormatShapes(formats: formats)
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(isSelected ? Theme.text : Theme.line, lineWidth: isSelected ? 2.5 : 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .help(blurb)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Tiny outlines at each export format's ratio: landscape, vertical,
/// square. Solid, because they're the formats this purpose makes.
struct HomeFormatShapes: View {
    let formats: [String]

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(formats.prefix(3).enumerated()), id: \.offset) { _, format in
                let size = Self.size(of: format)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Theme.text, lineWidth: 1.5)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(height: 26, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    static func size(of format: String) -> CGSize {
        switch format {
        case "vertical": return CGSize(width: 12, height: 22)
        case "square": return CGSize(width: 22, height: 22)
        default: return CGSize(width: 30, height: 17)
        }
    }
}
