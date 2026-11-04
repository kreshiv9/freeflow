import Foundation

/// Three-way merges for the Settings vocabulary and corrections editors. An editor keeps a
/// draft and the stored value it started from (the base); whatever changed the stored value
/// meanwhile (Paste Custom Word to Vocabulary, a learned rule moved to Corrections) is merged
/// with the user's edits instead of being overwritten by a stale draft.
enum VocabularyDraftMerge {
    /// Edits are saved this long after the last change, and at once on focus loss, when the
    /// editor disappears and when the app quits.
    static let saveDelaySeconds: TimeInterval = 0.3

    /// The Custom Vocabulary entries: split on newlines, commas and semicolons, trimmed,
    /// empties dropped (the separators cleanup, cursor fitting and Deepgram use).
    static func entries(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Lowercased with whitespace runs collapsed.
    static func key(_ entry: String) -> String {
        LearnedVocabulary.key(entry)
    }

    /// The text to store, on trimmed values. An unedited draft takes the stored text; an edit
    /// over an unchanged stored text is the draft. When both changed, the draft keeps the
    /// user's edits and gains every stored entry that is in neither the base nor the draft
    /// (added elsewhere, and neither typed nor deleted by the user). Removals made elsewhere
    /// are not merged: nothing outside the editor removes manual entries.
    static func merge(base: String, draft: String, stored: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft == base { return stored }
        if stored == base { return draft }
        let known = Set((entries(base) + entries(draft)).map(key))
        return appending(entries(stored).filter { !known.contains(key($0)) }, to: draft)
    }

    /// `text` with the entries it lacks (compared case-insensitively) appended the way Paste
    /// Custom Word to Vocabulary appends: a comma, a new line, then the entries joined by ", ".
    /// Unchanged when nothing is new.
    static func appending(_ newEntries: [String], to text: String) -> String {
        var seen = Set(entries(text).map(key))
        let added = newEntries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(key($0)).inserted }
        guard !added.isEmpty else { return text }
        let joined = added.joined(separator: ", ")
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return joined }
        if !result.hasSuffix(",") { result += "," }
        return result + "\n" + joined
    }

    /// Rows matched by id. A draft row that is new or that the user changed (compared
    /// normalized) wins. A row the user left alone follows the stored row, keeping the
    /// draft's own form when the stored row is unchanged too, and is dropped when it was
    /// removed elsewhere. Stored rows in neither the draft nor the base (added elsewhere)
    /// follow the draft's rows.
    static func merge(
        base: [DictionaryCorrection],
        draft: [DictionaryCorrection],
        stored: [DictionaryCorrection]
    ) -> [DictionaryCorrection] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let storedByID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [DictionaryCorrection] = []
        for row in draft {
            guard let baseRow = baseByID[row.id], row.normalized == baseRow.normalized else {
                merged.append(row)
                continue
            }
            guard let storedRow = storedByID[row.id] else { continue }
            merged.append(storedRow.normalized == baseRow.normalized ? row : storedRow)
        }
        let draftIDs = Set(draft.map(\.id))
        merged += stored.filter { !draftIDs.contains($0.id) && baseByID[$0.id] == nil }
        return merged
    }
}

/// The Custom Vocabulary editor's state: the text being edited and the stored value it is
/// based on.
struct VocabularyDraft: Equatable {
    var text: String
    private(set) var base: String

    init(stored: String) {
        text = stored
        base = stored
    }

    /// The text differs from the base beyond surrounding whitespace.
    var hasEdits: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored value changed. Our own write (equal to the base) is ignored, so a trailing
    /// newline the user just typed stays; an unedited draft follows the stored value; an
    /// edited one is kept for the next commit to merge.
    mutating func storedDidChange(to stored: String) {
        guard stored != base, !hasEdits else { return }
        text = stored
        base = stored
    }

    /// The value to store, or nil when the stored value is already right. The text is
    /// rewritten only when changes made elsewhere were merged in, so typing is never
    /// disturbed by trimming.
    mutating func commit(stored: String) -> String? {
        let merged = VocabularyDraftMerge.merge(base: base, draft: text, stored: stored)
        if merged != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            text = merged
        }
        base = merged
        return merged == stored ? nil : merged
    }
}

/// The Corrections editor's state: the rows being edited and the stored rows they are based on.
struct CorrectionsDraft: Equatable {
    var rows: [DictionaryCorrection]
    private(set) var base: [DictionaryCorrection]

    init(stored: [DictionaryCorrection]) {
        rows = stored
        base = stored
    }

    /// The stored rows changed: merge them into the rows being edited. Our own write (equal
    /// to the base) is ignored.
    mutating func storedDidChange(to stored: [DictionaryCorrection]) {
        guard stored != base else { return }
        rows = VocabularyDraftMerge.merge(base: base, draft: rows, stored: stored)
        base = stored
    }

    /// The rows to store (normalized, blank rows left out), or nil when the stored rows are
    /// already right. The displayed rows are not normalized here, so a debounced save never
    /// trims a space the user just typed; they change only when rows from elsewhere merged in.
    mutating func commit(stored: [DictionaryCorrection]) -> [DictionaryCorrection]? {
        let merged = VocabularyDraftMerge.merge(base: base, draft: rows, stored: stored)
        if merged != rows { rows = merged }
        let persisted = merged.map(\.normalized).filter { !$0.isBlank }
        base = persisted
        return persisted == stored ? nil : persisted
    }

    /// Trims and cuts every row to the field limit, as on focus loss and Return.
    mutating func normalizeRows() {
        rows = rows.map(\.normalized)
    }
}
