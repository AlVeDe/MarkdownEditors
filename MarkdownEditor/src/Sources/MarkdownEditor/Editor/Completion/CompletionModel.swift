import Foundation

// MARK: - Fuzzy matching

/// Case-insensitive fuzzy matching of what the user typed against a
/// completion's filter text.
///
/// Three tiers, best first, so that typing a prefix always wins over a
/// scattered match:
/// - `.prefix`        `alp` → `alpha`
/// - `.wordBoundary`  every typed character starts a word or continues the
///                    previous matched character: `lr` → `leftrightarrow`
///                    does not qualify, `la` → `left-arrow`, `bar` → `foo_bar`,
///                    `RA` → `RightArrow` do
/// - `.subsequence`   the characters appear in order: `lra` → `leftrightarrow`
enum FuzzyMatcher {
    enum Tier: Int, Comparable {
        case subsequence = 1, wordBoundary = 2, prefix = 3
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    struct Match: Equatable {
        var tier: FuzzyMatcher.Tier
        /// Character (grapheme) offsets in the candidate that matched, for
        /// highlighting.
        var matchedIndices: [Int]
    }

    /// Nil when `query` is not a subsequence of `candidate`. An empty query
    /// matches everything as a prefix.
    static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased())
        let original = Array(candidate)
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else { return Match(tier: .prefix, matchedIndices: []) }
        // Lowercasing can change the character count (rare: "İ"); fall back
        // to the original characters so indices stay aligned.
        let lower = c.count == original.count ? c : original
        guard q.count <= lower.count else { return nil }

        if lower.starts(with: q) {
            return Match(tier: .prefix, matchedIndices: Array(0..<q.count))
        }
        if let indices = boundaryMatch(q, lower, original) {
            return Match(tier: .wordBoundary, matchedIndices: indices)
        }
        // Greedy leftmost subsequence.
        var indices: [Int] = []
        var qi = 0
        for (ci, ch) in lower.enumerated() where qi < q.count && ch == q[qi] {
            indices.append(ci)
            qi += 1
        }
        return qi == q.count ? Match(tier: .subsequence, matchedIndices: indices) : nil
    }

    /// True when position `i` starts a word: the first character, after a
    /// non-alphanumeric character, or a lower→upper camel-case hump.
    private static func isWordStart(_ i: Int, _ original: [Character]) -> Bool {
        if i == 0 { return true }
        let previous = original[i - 1]
        let current = original[i]
        if !(previous.isLetter || previous.isNumber) { return current.isLetter || current.isNumber }
        return previous.isLowercase && current.isUppercase
    }

    /// Depth-first search for a match where each query character lands on a
    /// word start or directly after the previous matched character. Failed
    /// (query, candidate, contiguous) states are memoized, so it stays
    /// O(|q|·|c|).
    private static func boundaryMatch(_ q: [Character], _ c: [Character], _ original: [Character]) -> [Int]? {
        var failed = Set<Int>()
        var path: [Int] = []
        func search(_ qi: Int, _ from: Int) -> Bool {
            if qi == q.count { return true }
            let key = qi * (c.count + 1) + from
            if failed.contains(key) { return false }
            for ci in from..<c.count where c[ci] == q[qi] {
                let contiguous = path.last.map { $0 == ci - 1 } ?? false
                guard contiguous || isWordStart(ci, original) else { continue }
                path.append(ci)
                if search(qi + 1, ci + 1) { return true }
                path.removeLast()
            }
            failed.insert(key)
            return false
        }
        return search(0, 0) ? path : nil
    }
}

// MARK: - List model

/// The popup's state without any UI: the provider's items, what the user has
/// typed so far, the filtered and ranked list and the selection. The window
/// only renders this, which is what makes filtering, selection and
/// acceptance unit-testable.
struct CompletionListModel {
    struct Entry {
        var item: CompletionItem
        var tier: FuzzyMatcher.Tier
        /// Matched character offsets in `item.label` (for highlighting).
        var labelHighlights: [Int]
        /// Position in the provider's list; the last tie-breaker.
        var originalIndex: Int
    }

    let items: [CompletionItem]
    /// Where the replaced text starts in the document.
    let anchor: Int
    /// Characters of the original replacement range after the caret at the
    /// time of the request (a provider may replace a whole word around the
    /// caret); kept so acceptance still replaces them.
    let trailingLength: Int

    private(set) var query = ""
    private(set) var entries: [Entry] = []
    private(set) var selectedIndex = 0

    init(result: CompletionResult, caret: Int) {
        items = result.items
        anchor = result.replacementRange.location
        trailingLength = max(0, NSMaxRange(result.replacementRange) - caret)
    }

    var selectedEntry: Entry? { entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil }
    var selectedItem: CompletionItem? { selectedEntry?.item }
    var isEmpty: Bool { entries.isEmpty }

    /// The document range accepting an item replaces, given the caret.
    func replacementRange(caret: Int) -> NSRange {
        NSRange(location: anchor, length: max(0, caret - anchor) + trailingLength)
    }

    /// Re-filters and re-ranks for `query`. Keeps the selected item selected
    /// when it still matches; otherwise selects the best match.
    mutating func filter(_ query: String) {
        let previous = selectedItem?.id
        let queryChanged = query != self.query
        self.query = query
        entries = items.enumerated().compactMap { index, item in
            let filterText = item.filterText ?? item.label
            guard let match = FuzzyMatcher.match(query, in: filterText) else { return nil }
            let highlights = filterText == item.label
                ? match.matchedIndices
                : FuzzyMatcher.match(query, in: item.label)?.matchedIndices ?? []
            return Entry(item: item, tier: match.tier, labelHighlights: highlights, originalIndex: index)
        }
        entries.sort(by: Self.ranksBefore)
        // While typing, the best match should be selected (as in Xcode); the
        // previous selection only survives a re-filter with the same query.
        if !queryChanged, let previous, let index = entries.firstIndex(where: { $0.item.id == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
    }

    /// Ranking: tier, then the provider's `sortPriority`, then the shorter
    /// label, then the provider's order.
    static func ranksBefore(_ a: Entry, _ b: Entry) -> Bool {
        if a.tier != b.tier { return a.tier > b.tier }
        if a.item.sortPriority != b.item.sortPriority { return a.item.sortPriority > b.item.sortPriority }
        let la = a.item.label.count, lb = b.item.label.count
        if la != lb { return la < lb }
        return a.originalIndex < b.originalIndex
    }

    /// Moves the selection, clamped to the list (no wrap-around, like the
    /// Xcode and VS Code popups when paging).
    mutating func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = min(entries.count - 1, max(0, selectedIndex + delta))
    }

    /// Up/Down wrap around at the ends.
    mutating func moveSelectionWrapping(by delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = ((selectedIndex + delta) % entries.count + entries.count) % entries.count
    }

    mutating func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selectedIndex = index
    }
}
