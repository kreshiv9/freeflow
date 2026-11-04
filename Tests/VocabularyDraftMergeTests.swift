import Foundation

/// The Settings editors' three-way merge (B1): edits are never lost and words or rules added
/// elsewhere while the editor is open are never overwritten. Invented words only.
enum VocabularyDraftMergeTests {
    private typealias Merge = VocabularyDraftMerge

    static func run() {
        testEntriesAndAppending()
        testVocabularyMerge()
        testVocabularyDraft()
        testCorrectionsMerge()
        testCorrectionsDraft()
    }

    private static func testEntriesAndAppending() {
        TestSupport.expectEqual(Merge.entries(" Alpha,\nBeta;\r\n  ,Gamma Delta "), ["Alpha", "Beta", "Gamma Delta"])
        TestSupport.expectEqual(Merge.key("  Gamma   Delta "), "gamma delta")
        TestSupport.expectEqual(Merge.saveDelaySeconds, 0.3)
        // The same layout as Paste Custom Word to Vocabulary.
        TestSupport.expectEqual(Merge.appending(["Beta", "Gamma"], to: "Alpha"), "Alpha,\nBeta, Gamma")
        TestSupport.expectEqual(Merge.appending(["Beta"], to: "Alpha,"), "Alpha,\nBeta")
        TestSupport.expectEqual(Merge.appending(["Beta"], to: "  "), "Beta")
        TestSupport.expectEqual(Merge.appending(["alpha", "Beta", "beta"], to: "Alpha"), "Alpha,\nBeta")
        TestSupport.expectEqual(Merge.appending(["ALPHA"], to: "Alpha\n"), "Alpha\n")
    }

    private static func testVocabularyMerge() {
        // V1 an unedited draft follows the stored value.
        TestSupport.expectEqual(Merge.merge(base: "Alpha", draft: "Alpha", stored: "Alpha,\nGamma"), "Alpha,\nGamma")
        // V2 an edited draft wins when the stored value is unchanged.
        TestSupport.expectEqual(Merge.merge(base: "Alpha", draft: "Alpha, Beta", stored: "Alpha"), "Alpha, Beta")
        // V3 both changed: the user's edit plus the word added elsewhere.
        TestSupport.expectEqual(Merge.merge(base: "Alpha", draft: "Alpha, Beta", stored: "Alpha,\nGamma"), "Alpha, Beta,\nGamma")
        // V4 an entry the user deleted stays deleted.
        TestSupport.expectEqual(Merge.merge(base: "Alpha, Beta", draft: "Alpha", stored: "Alpha, Beta,\nGamma"), "Alpha,\nGamma")
        // V5 the same entry added on both sides appears once.
        TestSupport.expectEqual(Merge.merge(base: "Alpha", draft: "Alpha, Beta", stored: "Alpha,\nbeta"), "Alpha, Beta")
        // V6 trailing whitespace alone is not an edit.
        TestSupport.expectEqual(Merge.merge(base: "Alpha", draft: "Alpha\n\n", stored: "Alpha,\nGamma"), "Alpha,\nGamma")
        // V7 a cleared draft plus a menu-added word keeps the word.
        TestSupport.expectEqual(Merge.merge(base: "Alpha", draft: "", stored: "Alpha,\nGamma"), "Gamma")
    }

    private static func testVocabularyDraft() {
        // D1 nothing to write.
        var draft = VocabularyDraft(stored: "Alpha")
        TestSupport.expect(draft.commit(stored: "Alpha") == nil, "an unchanged draft writes nothing")
        TestSupport.expect(!draft.hasEdits, "no edits")

        // D2 an unedited draft follows the stored value.
        draft.storedDidChange(to: "Alpha,\nGamma")
        TestSupport.expectEqual(draft.text, "Alpha,\nGamma")
        TestSupport.expectEqual(draft.base, "Alpha,\nGamma")

        // D3 an edited draft is kept; the commit merges and the text shows the merge.
        var edited = VocabularyDraft(stored: "Alpha")
        edited.text = "Alpha, Beta"
        TestSupport.expect(edited.hasEdits, "typing is an edit")
        edited.storedDidChange(to: "Alpha,\nGamma")
        TestSupport.expectEqual(edited.text, "Alpha, Beta")
        TestSupport.expectEqual(edited.commit(stored: "Alpha,\nGamma"), "Alpha, Beta,\nGamma")
        TestSupport.expectEqual(edited.text, "Alpha, Beta,\nGamma")
        TestSupport.expectEqual(edited.base, "Alpha, Beta,\nGamma")

        // D4 the echo of our own write keeps a trailing newline the user just typed.
        var typing = VocabularyDraft(stored: "Alpha")
        typing.text = "Alpha, Beta"
        let written = typing.commit(stored: "Alpha")
        TestSupport.expectEqual(written, "Alpha, Beta")
        typing.text = "Alpha, Beta\n"
        typing.storedDidChange(to: "Alpha, Beta")
        TestSupport.expectEqual(typing.text, "Alpha, Beta\n")
        TestSupport.expect(typing.commit(stored: "Alpha, Beta") == nil, "a trailing newline alone writes nothing")
        TestSupport.expectEqual(typing.text, "Alpha, Beta\n")

        // D5 the commit stores the trimmed value without rewriting the user's text.
        var spaced = VocabularyDraft(stored: "Alpha")
        spaced.text = "Alpha, Beta, "
        TestSupport.expectEqual(spaced.commit(stored: "Alpha"), "Alpha, Beta,")
        TestSupport.expectEqual(spaced.text, "Alpha, Beta, ")

        // A commit that races a menu add while the draft is unedited takes the stored value.
        var racing = VocabularyDraft(stored: "Alpha")
        TestSupport.expect(racing.commit(stored: "Alpha,\nGamma") == nil, "the stored value is already right")
        TestSupport.expectEqual(racing.text, "Alpha,\nGamma")
    }

    private static func row(_ from: String, _ to: String, id: UUID = UUID()) -> DictionaryCorrection {
        DictionaryCorrection(id: id, from: from, to: to)
    }

    private static func testCorrectionsMerge() {
        let a = row("versel", "Vercel"), b = row("kwen", "Qwen")
        // C1 a row added elsewhere is kept while another row is edited.
        var editedA = a
        editedA.to = "Vercel Inc"
        let moved = row("grok", "Groq")
        TestSupport.expectEqual(Merge.merge(base: [a, b], draft: [editedA, b], stored: [a, b, moved]), [editedA, b, moved])
        // C2 a row the user removed stays removed.
        TestSupport.expectEqual(Merge.merge(base: [a, b], draft: [a], stored: [a, b]), [a])
        // C4 an unedited row takes the stored update.
        var storedB = b
        storedB.to = "Qwen 3"
        TestSupport.expectEqual(Merge.merge(base: [a, b], draft: [a, b], stored: [a, storedB]), [a, storedB])
        // C5 a row the user edited survives its removal elsewhere.
        TestSupport.expectEqual(Merge.merge(base: [a, b], draft: [editedA, b], stored: [b]), [editedA, b])
        // An unedited row removed elsewhere goes.
        TestSupport.expectEqual(Merge.merge(base: [a, b], draft: [a, b], stored: [b]), [b])
        // An unedited row keeps its displayed form when the stored row is unchanged too.
        let typed = row("versel ", "Vercel", id: a.id)
        TestSupport.expectEqual(Merge.merge(base: [a], draft: [typed], stored: [a]), [typed])
    }

    private static func testCorrectionsDraft() {
        let a = row("versel", "Vercel")
        // C3 a blank new row stays in the rows and is not persisted.
        var draft = CorrectionsDraft(stored: [a])
        let blank = row("", "")
        draft.rows.append(blank)
        TestSupport.expect(draft.commit(stored: [a]) == nil, "a blank row writes nothing")
        TestSupport.expectEqual(draft.rows, [a, blank])

        // C6 a debounced commit does not trim the displayed "Claude " while the stored rule is normalized.
        let typing = row("cloud", "Claude ")
        draft.rows = [a, typing]
        TestSupport.expectEqual(draft.commit(stored: [a]), [a, typing.normalized])
        TestSupport.expectEqual(draft.rows, [a, typing])
        // The echo of that write changes nothing.
        draft.storedDidChange(to: [a, typing.normalized])
        TestSupport.expectEqual(draft.rows, [a, typing])
        TestSupport.expect(draft.commit(stored: [a, typing.normalized]) == nil, "nothing more to write")
        // Focus loss normalizes the rows.
        draft.normalizeRows()
        TestSupport.expectEqual(draft.rows, [a, typing.normalized])

        // A learned rule moved to Corrections while a row is being edited.
        var editing = CorrectionsDraft(stored: [a])
        var editedA = a
        editedA.to = "Vercel Inc"
        editing.rows = [editedA]
        let moved = row("grok", "Groq")
        editing.storedDidChange(to: [a, moved])
        TestSupport.expectEqual(editing.rows, [editedA, moved])
        TestSupport.expectEqual(editing.commit(stored: [a, moved]), [editedA, moved])
        TestSupport.expectEqual(editing.base, [editedA, moved])
    }
}
