import AppKit
import SwiftUI

/// Spec §8 Stage 2/3 — arbitrary cross-segment text selection over the transcript, replacing the
/// old per-segment star-button toggle. Plain SwiftUI `Text` has no API to report a selected
/// character range across sibling views (no `.onSelectionChange` for a bare `Text`, unlike
/// `TextEditor`), so this drops to AppKit the same way `PlayerView` did for `AVPlayerView` (spec
/// §8 Video playback) — the whole transcript is rendered as ONE `NSTextView` so a drag can cross
/// segment boundaries and still resolve to a single, real character range.
///
/// **Deliberate scope trade-off**: the old inline "double-click to edit text/speaker in place"
/// affordance (`SegmentRow`'s `TextField` swap) can't survive this — there's no per-segment
/// `Binding<TranscriptSegment>` once every segment's text lives in one shared text storage.
/// Double-click now opens a small edit popover for that one segment instead (`TranscriptPanel`),
/// calling the exact same `onEditSegment`/`onRenameSpeaker` plumbing as before — the underlying
/// persistence is unchanged, only the editing UI's shell is.
struct TranscriptSelectionRange: Equatable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    /// True only when *both* selection boundaries resolved to real word timing — false if either
    /// end fell back to a whole segment's `start`/`end` (Gemini transcripts, or pre-Stage-1
    /// legacy data with `words == nil`). Purely informational (e.g. for a future "approximate"
    /// badge); does not change how the range is used.
    var isWordLevel: Bool
}

/// One resolvable span inside the flowing transcript's backing text storage — either a real word
/// (word-level timing available) or a whole segment (fallback unit for a segment with no `words`).
/// `range` is in the `NSTextStorage`'s character coordinates, not the source `TranscriptSegment`'s.
private struct FlowUnit {
    let range: NSRange
    let start: TimeInterval
    let end: TimeInterval
    let segmentIndex: Int
    let isWord: Bool
}

private struct FlowParagraph {
    let range: NSRange
    let segmentIndex: Int
}

private let audiumPrefixAttribute = NSAttributedString.Key("com.postproduction.Audium.prefix")

struct TranscriptFlowView: NSViewRepresentable {
    let segments: [TranscriptSegment]
    let highlights: [Highlight]
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onSelectionChange: (TranscriptSelectionRange?, CGRect?) -> Void
    let onDoubleClickSegment: (Int) -> Void
    let onRightClickAddHighlight: () -> Void
    let onRightClickAddToPaperEdit: (UUID?) -> Void
    let paperEdits: [PaperEdit]
    /// False for a standalone (no-project) file — there's no Daily to persist a Highlight to
    /// (same constraint the old per-segment star button followed). Gates the right-click
    /// "Add Highlight"/"Add to Paper Edit" items out of the context menu entirely rather than
    /// showing them disabled or silently no-op'ing when clicked.
    let canHighlight: Bool
    /// Set to true by `TranscriptPanel` after a selection is successfully turned into a Highlight
    /// (or otherwise dismissed) — the SwiftUI-side `selectionRange`/`selectionRect` going nil hides
    /// the floating action bar, but the `NSTextView`'s own native blue selection highlight needs an
    /// explicit `setSelectedRange` to actually clear, since nothing else here owns that state.
    @Binding var clearSelectionRequest: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FlowTextView()
        textView.coordinator = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        context.coordinator.rebuild(in: textView)
        context.coordinator.applyHighlightBackgrounds(in: textView)
        context.coordinator.updateCurrentSegmentHighlight(in: textView)
        if clearSelectionRequest {
            // Suppress the click-to-seek side effect `textViewDidChangeSelection` would otherwise
            // fire for this *programmatic* zero-length selection — without it, every successful
            // "Add Highlight"/"Add to Paper Edit" would immediately jerk playback back to whatever
            // segment character index 0 resolves to (real bug caught before this ever reached a
            // GUI test). Only worth doing if the selection isn't already empty — `updateNSView`
            // re-runs (e.g. the same highlight-add mutating `@Published` state that set
            // `clearSelectionRequest`) can fire again before the `DispatchQueue.main.async` reset
            // below has landed; a second `setSelectedRange` call with the *same* already-empty
            // range doesn't re-notify the delegate (AppKit only notifies on an actual change), so
            // the flag would get re-armed but never consumed — silently eating the next real
            // click-to-seek (caught via adversarial review, not live).
            if textView.selectedRange().length > 0 {
                context.coordinator.suppressNextSelectionSeek = true
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            DispatchQueue.main.async { self.clearSelectionRequest = false }
        }
    }

    final class FlowTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let coordinator {
                let point = convert(event.locationInWindow, from: nil)
                let charIndex = characterIndexForInsertion(at: point)
                if let segmentIndex = coordinator.segmentIndex(atCharacterIndex: charIndex) {
                    coordinator.parent.onDoubleClickSegment(segmentIndex)
                    return
                }
            }
            super.mouseDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let coordinator, coordinator.parent.canHighlight, selectedRange().length > 0 else { return super.menu(for: event) }
            let menu = NSMenu()
            menu.addItem(withTitle: "Add Highlight", action: #selector(Coordinator.menuAddHighlight), keyEquivalent: "")
                .target = coordinator
            let paperEditItem = NSMenuItem(title: "Add to Paper Edit", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for paperEdit in coordinator.parent.paperEdits {
                let item = submenu.addItem(withTitle: paperEdit.name, action: #selector(Coordinator.menuAddToPaperEdit(_:)), keyEquivalent: "")
                item.target = coordinator
                item.representedObject = paperEdit.id
            }
            if !coordinator.parent.paperEdits.isEmpty { submenu.addItem(.separator()) }
            let newItem = submenu.addItem(withTitle: "New Paper Edit…", action: #selector(Coordinator.menuAddToPaperEdit(_:)), keyEquivalent: "")
            newItem.target = coordinator
            newItem.representedObject = nil as UUID?
            paperEditItem.submenu = submenu
            menu.addItem(paperEditItem)
            menu.addItem(.separator())
            if let defaultMenu = super.menu(for: event) {
                for item in defaultMenu.items {
                    defaultMenu.removeItem(item)
                    menu.addItem(item)
                }
            }
            return menu
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptFlowView
        weak var textView: FlowTextView?
        private var units: [FlowUnit] = []
        private var paragraphs: [FlowParagraph] = []
        private var lastSignature = ""
        private var lastHighlightsSignature = ""
        private var currentSegmentBackgroundRange: NSRange?
        var suppressNextSelectionSeek = false

        init(_ parent: TranscriptFlowView) {
            self.parent = parent
        }

        /// Rebuilds the backing attributed string only when the segments actually changed shape
        /// (count/text/words) — re-running this on every ~50ms playhead tick (`updateNSView` fires
        /// constantly while playing) would otherwise thrash the whole text storage and blow away
        /// the user's live selection every frame.
        func rebuild(in textView: FlowTextView) {
            let signature = parent.segments.map { "\($0.text)|\($0.speaker ?? "")|\($0.words?.count ?? -1)" }.joined(separator: "\u{1}")
            guard signature != lastSignature else { return }
            lastSignature = signature
            currentSegmentBackgroundRange = nil

            let result = NSMutableAttributedString()
            var newUnits: [FlowUnit] = []
            var newParagraphs: [FlowParagraph] = []

            for (index, segment) in parent.segments.enumerated() {
                let paragraphStart = result.length
                let prefixText = segment.speaker.map { "[\(formatTime(segment.start))] \($0): " } ?? "[\(formatTime(segment.start))] "
                let prefixAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor(Theme.accent),
                    audiumPrefixAttribute: true,
                ]
                result.append(NSAttributedString(string: prefixText, attributes: prefixAttrs))

                let bodyStart = result.length
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                ]
                result.append(NSAttributedString(string: segment.text, attributes: bodyAttrs))

                if let words = segment.words, !words.isEmpty {
                    var cursor = 0
                    let bodyNS = segment.text as NSString
                    var wordUnits: [FlowUnit] = []
                    var matchFailed = false
                    for word in words {
                        let searchRange = NSRange(location: cursor, length: bodyNS.length - cursor)
                        let found = bodyNS.range(of: word.text, options: [.literal], range: searchRange)
                        guard found.location != NSNotFound else { matchFailed = true; break }
                        wordUnits.append(FlowUnit(
                            range: NSRange(location: bodyStart + found.location, length: found.length),
                            start: word.start, end: word.end, segmentIndex: index, isWord: true
                        ))
                        cursor = found.location + found.length
                    }
                    if matchFailed {
                        newUnits.append(FlowUnit(range: NSRange(location: bodyStart, length: bodyNS.length), start: segment.start, end: segment.end, segmentIndex: index, isWord: false))
                    } else {
                        newUnits.append(contentsOf: wordUnits)
                    }
                } else {
                    newUnits.append(FlowUnit(range: NSRange(location: bodyStart, length: result.length - bodyStart), start: segment.start, end: segment.end, segmentIndex: index, isWord: false))
                }

                newParagraphs.append(FlowParagraph(range: NSRange(location: paragraphStart, length: result.length - paragraphStart), segmentIndex: index))
                result.append(NSAttributedString(string: "\n\n"))
            }

            units = newUnits
            paragraphs = newParagraphs
            textView.textStorage?.setAttributedString(result)
            lastHighlightsSignature = ""
            applyHighlightBackgrounds(in: textView)
        }

        /// Repaints highlight background tints whenever `parent.highlights` actually changed —
        /// called every `updateNSView`, independent of `rebuild()`'s text-change guard. Without
        /// this separate check, adding a Highlight from a selection (which doesn't change any
        /// segment's text/words) would never re-run `rebuild()` at all, so a just-created
        /// Highlight would silently never get its background tint — text and highlight state
        /// change on different triggers, so they need independent change detection.
        func applyHighlightBackgrounds(in textView: FlowTextView) {
            let signature = parent.highlights.map { "\($0.id)|\($0.start)|\($0.end)" }.joined(separator: "\u{1}")
            guard signature != lastHighlightsSignature else { return }
            lastHighlightsSignature = signature
            guard let storage = textView.textStorage else { return }
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            for highlight in parent.highlights {
                let matched = units.filter { $0.end > highlight.start && $0.start < highlight.end }
                guard let first = matched.first, let last = matched.last else { continue }
                // One contiguous range spanning the first matched unit through the last, not one
                // `addAttribute` call per word — painting only each word's own range left the
                // inter-word spaces (part of the paragraph's text but not any `FlowUnit`)
                // untinted, rendering a multi-word highlight as gap-broken slivers instead of one
                // solid span (caught via adversarial review).
                let start = first.range.location
                let end = last.range.location + last.range.length
                storage.addAttribute(.backgroundColor, value: NSColor(Theme.accent).withAlphaComponent(0.16), range: NSRange(location: start, length: end - start))
            }
        }

        /// Only touches the one paragraph whose background needs to change, rather than rebuilding
        /// or re-scanning everything — this runs on every playhead tick.
        func updateCurrentSegmentHighlight(in textView: FlowTextView) {
            guard let storage = textView.textStorage else { return }
            let newRange = paragraphs.last { segmentStart(of: $0.segmentIndex) <= parent.currentTime }?.range
            guard newRange != currentSegmentBackgroundRange else { return }
            if let old = currentSegmentBackgroundRange, old.location + old.length <= storage.length {
                storage.removeAttribute(.underlineStyle, range: old)
            }
            if let newRange {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: newRange)
            }
            currentSegmentBackgroundRange = newRange
        }

        private func segmentStart(of index: Int) -> TimeInterval {
            guard parent.segments.indices.contains(index) else { return 0 }
            return parent.segments[index].start
        }

        func segmentIndex(atCharacterIndex charIndex: Int) -> Int? {
            paragraphs.first { NSLocationInRange(charIndex, $0.range) }?.segmentIndex
        }

        private func unit(containing charIndex: Int) -> FlowUnit? {
            units.first { NSLocationInRange(charIndex, $0.range) }
        }

        // MARK: - NSTextViewDelegate

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = textView else { return }
            let selected = textView.selectedRange()

            guard selected.length > 0 else {
                parent.onSelectionChange(nil, nil)
                if suppressNextSelectionSeek {
                    suppressNextSelectionSeek = false
                } else if let segmentIndex = segmentIndex(atCharacterIndex: selected.location) {
                    parent.onSeek(parent.segments[segmentIndex].start)
                }
                return
            }

            // A boundary landing in a gap (a segment's "[00:23] Speaker: " prefix, or the "\n\n"
            // separator between segments — neither belongs to any `FlowUnit`) needs a
            // direction-aware fallback, not just "nearest unit": the start boundary should reach
            // *forward* into whatever real content comes next (a gap always precedes real
            // content), and the end boundary should reach *backward* into whatever real content
            // came before (a gap always follows real content). Getting this backwards (confirmed
            // via adversarial review, not live-caught) silently anchored a selection that started
            // inside a segment's prefix to the *previous* segment's last word instead.
            let startUnit = unit(containing: selected.location) ?? units.first { $0.range.location >= selected.location }
            let endUnit = unit(containing: max(selected.location, selected.location + selected.length - 1)) ?? units.last { $0.range.location <= selected.location + selected.length - 1 }
            guard let startUnit, let endUnit else {
                parent.onSelectionChange(nil, nil)
                return
            }

            let range = TranscriptSelectionRange(
                start: min(startUnit.start, endUnit.start),
                end: max(startUnit.end, endUnit.end),
                isWordLevel: startUnit.isWord && endUnit.isWord
            )

            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
                parent.onSelectionChange(range, nil)
                return
            }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: selected, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            if let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin {
                rect.origin.x -= scrollOrigin.x
                rect.origin.y -= scrollOrigin.y
            }
            parent.onSelectionChange(range, rect)
        }

        // MARK: - Context menu actions

        @objc func menuAddHighlight() {
            parent.onRightClickAddHighlight()
        }

        @objc func menuAddToPaperEdit(_ sender: NSMenuItem) {
            parent.onRightClickAddToPaperEdit(sender.representedObject as? UUID)
        }
    }
}
