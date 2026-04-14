import Foundation
import SwiftUI

#if os(macOS)
import AppKit
private typealias PlatformViewRepresentable = NSViewRepresentable
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor
#else
import UIKit
private typealias PlatformViewRepresentable = UIViewRepresentable
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor
#endif

struct SelectableMarkdownText: View {
    enum SegmentRole {
        case assistant
        case thinking
    }

    struct Segment: Hashable {
        let markdown: String
        let role: SegmentRole
    }

    let segments: [Segment]

    @State private var measuredHeight: CGFloat = 1

    private var renderedText: NSAttributedString {
        MarkdownAttributedStringBuilder.render(segments: segments)
    }

    var body: some View {
        GeometryReader { proxy in
            SelectableMarkdownPlatformTextView(
                attributedText: renderedText,
                availableWidth: max(proxy.size.width, 1),
                measuredHeight: $measuredHeight
            )
        }
        .frame(height: max(measuredHeight, 1))
    }
}

private struct MarkdownAttributedStringBuilder {
    private struct RenderRun {
        let blockKey: String
        let blockStyle: BlockStyle
        let text: String
        let inlineIntent: Int
        let link: URL?
    }

    private enum BlockStyle: Equatable {
        case paragraph
        case heading(level: Int)
        case unorderedListItem
        case orderedListItem(number: Int)
        case blockQuote
        case codeBlock
    }

    static func render(segments: [SelectableMarkdownText.Segment]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let filteredSegments = segments.filter { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for (index, segment) in filteredSegments.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n\n"))
            }
            output.append(renderSegment(segment))
        }

        return output
    }

    private static func renderSegment(_ segment: SelectableMarkdownText.Segment) -> NSAttributedString {
        guard let parsed = try? NSAttributedString(
            markdown: Data(segment.markdown.utf8),
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            ),
            baseURL: nil
        ) else {
            return NSAttributedString(
                string: segment.markdown,
                attributes: baseAttributes(for: segment.role, blockStyle: .paragraph, inlineIntent: 0, link: nil)
            )
        }

        let runs = runs(from: parsed)
        let output = NSMutableAttributedString()

        var currentBlockKey: String?
        var currentBlockStyle: BlockStyle = .paragraph

        for run in runs {
            if currentBlockKey != run.blockKey {
                if currentBlockKey != nil {
                    output.append(NSAttributedString(string: "\n\n"))
                }
                currentBlockKey = run.blockKey
                currentBlockStyle = run.blockStyle
                let prefix = blockPrefix(for: run.blockStyle)
                if !prefix.isEmpty {
                    output.append(NSAttributedString(
                        string: prefix,
                        attributes: baseAttributes(for: segment.role, blockStyle: run.blockStyle, inlineIntent: 0, link: nil)
                    ))
                }
            }

            output.append(NSAttributedString(
                string: normalizedText(run.text, for: currentBlockStyle),
                attributes: baseAttributes(
                    for: segment.role,
                    blockStyle: currentBlockStyle,
                    inlineIntent: run.inlineIntent,
                    link: run.link
                )
            ))
        }

        return output
    }

    private static func runs(from attributedString: NSAttributedString) -> [RenderRun] {
        var runs: [RenderRun] = []
        let fullRange = NSRange(location: 0, length: attributedString.length)

        attributedString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let text = attributedString.attributedSubstring(from: range).string
            let blockDescription = attributes[NSAttributedString.Key("NSPresentationIntent")]
                .map { String(describing: $0) } ?? ""
            let blockStyle = parseBlockStyle(from: blockDescription)
            let inlineIntent = attributes[NSAttributedString.Key("NSInlinePresentationIntent")] as? Int ?? 0
            let link = attributes[.link] as? URL

            runs.append(RenderRun(
                blockKey: blockDescription.isEmpty ? "paragraph-\(range.location)" : blockDescription,
                blockStyle: blockStyle,
                text: text,
                inlineIntent: inlineIntent,
                link: link
            ))
        }

        return runs
    }

    private static func parseBlockStyle(from description: String) -> BlockStyle {
        if description.contains("CodeBlock") {
            return .codeBlock
        }

        if description.contains("Header") {
            return .heading(level: extractFirstInt(in: description) ?? 1)
        }

        if description.contains("BlockQuote") {
            return .blockQuote
        }

        if description.contains("OrderedList") {
            return .orderedListItem(number: extractOrdinal(in: description) ?? 1)
        }

        if description.contains("UnorderedList") {
            return .unorderedListItem
        }

        return .paragraph
    }

    private static func extractFirstInt(in text: String) -> Int? {
        let matches = text.matches(of: /\((\d+)\)/)
        return matches.first.flatMap { Int($0.1) }
    }

    private static func extractOrdinal(in text: String) -> Int? {
        let matches = text.matches(of: /ordinal (\d+)/)
        return matches.first.flatMap { Int($0.1) }
    }

    private static func blockPrefix(for blockStyle: BlockStyle) -> String {
        switch blockStyle {
        case .paragraph, .heading, .codeBlock:
            return ""
        case .unorderedListItem:
            return "• "
        case .orderedListItem(let number):
            return "\(number). "
        case .blockQuote:
            return "▎ "
        }
    }

    private static func normalizedText(_ text: String, for blockStyle: BlockStyle) -> String {
        switch blockStyle {
        case .codeBlock:
            return text.replacingOccurrences(of: "\n$", with: "", options: .regularExpression)
        default:
            return text
        }
    }

    private static func baseAttributes(
        for role: SelectableMarkdownText.SegmentRole,
        blockStyle: BlockStyle,
        inlineIntent: Int,
        link: URL?
    ) -> [NSAttributedString.Key: Any] {
        let color: PlatformColor = role == .thinking ? .secondaryLabelCompatible : .labelCompatible
        let font = font(for: blockStyle, inlineIntent: inlineIntent)
        let paragraphStyle = paragraphStyle(for: blockStyle)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]

        if inlineIntent & 4 != 0 || blockStyle == .codeBlock {
            attributes[.backgroundColor] = PlatformColor.codeBackgroundCompatible
        }

        if let link {
            attributes[.link] = link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        return attributes
    }

    private static func paragraphStyle(for blockStyle: BlockStyle) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = 0

        switch blockStyle {
        case .paragraph:
            break
        case .heading:
            style.paragraphSpacingBefore = 2
        case .unorderedListItem, .orderedListItem:
            style.headIndent = 18
            style.firstLineHeadIndent = 0
        case .blockQuote:
            style.headIndent = 18
            style.firstLineHeadIndent = 0
        case .codeBlock:
            style.headIndent = 10
            style.firstLineHeadIndent = 10
            style.paragraphSpacingBefore = 2
        }

        return style
    }

    private static func font(for blockStyle: BlockStyle, inlineIntent: Int) -> PlatformFont {
        let baseSize = PlatformFont.bodySize

        if inlineIntent & 4 != 0 || blockStyle == .codeBlock {
            return PlatformFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        }

        var font = PlatformFont.systemFont(ofSize: baseSize)

        if case .heading(let level) = blockStyle {
            let size = switch level {
            case 1: baseSize * 1.45
            case 2: baseSize * 1.3
            case 3: baseSize * 1.18
            default: baseSize * 1.08
            }
            font = PlatformFont.systemFont(ofSize: size, weight: .semibold)
        } else if inlineIntent & 2 != 0 {
            font = PlatformFont.boldSystemFont(ofSize: baseSize)
        }

        if inlineIntent & 1 != 0 {
            #if os(macOS)
            let italicDescriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = PlatformFont(descriptor: italicDescriptor, size: font.pointSize) ?? font
            #else
            if let italicDescriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = PlatformFont(descriptor: italicDescriptor, size: font.pointSize)
            }
            #endif
        }

        if inlineIntent & 2 != 0, case .heading = blockStyle {
            return font
        }

        if inlineIntent & 2 != 0, inlineIntent & 1 != 0 {
            #if os(macOS)
            let boldItalicDescriptor = font.fontDescriptor.withSymbolicTraits([.bold, .italic])
            font = PlatformFont(descriptor: boldItalicDescriptor, size: font.pointSize) ?? font
            #else
            if let boldItalicDescriptor = font.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                font = PlatformFont(descriptor: boldItalicDescriptor, size: font.pointSize)
            }
            #endif
        }

        return font
    }
}

#if os(macOS)
private struct SelectableMarkdownPlatformTextView: PlatformViewRepresentable {
    let attributedText: NSAttributedString
    let availableWidth: CGFloat
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        textView.textStorage?.setAttributedString(attributedText)
        textView.textContainer?.containerSize = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        textView.frame.size.width = availableWidth
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let height = ceil(usedRect.height + textView.textContainerInset.height * 2)
        if abs(measuredHeight - height) > 0.5 {
            DispatchQueue.main.async {
                measuredHeight = max(height, 1)
            }
        }
    }
}
#else
private struct SelectableMarkdownPlatformTextView: PlatformViewRepresentable {
    let attributedText: NSAttributedString
    let availableWidth: CGFloat
    @Binding var measuredHeight: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = attributedText
        let fittingSize = textView.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude))
        if abs(measuredHeight - fittingSize.height) > 0.5 {
            DispatchQueue.main.async {
                measuredHeight = max(ceil(fittingSize.height), 1)
            }
        }
    }
}
#endif

private extension PlatformFont {
    static var bodySize: CGFloat {
        #if os(macOS)
        return NSFont.preferredFont(forTextStyle: .body).pointSize
        #else
        return UIFont.preferredFont(forTextStyle: .body).pointSize
        #endif
    }
}

private extension PlatformColor {
    static var labelCompatible: PlatformColor {
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    static var secondaryLabelCompatible: PlatformColor {
        #if os(macOS)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    static var codeBackgroundCompatible: PlatformColor {
        #if os(macOS)
        return .quaternaryLabelColor.withAlphaComponent(0.12)
        #else
        return .secondarySystemFill
        #endif
    }
}
