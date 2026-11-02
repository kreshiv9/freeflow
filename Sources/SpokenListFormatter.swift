import Foundation

/// Wispr-style Smart Formatting for counted lists, applied locally after cleanup when the model
/// left a clearly counted list as prose: "Things to buy first milk, second eggs, third bread"
/// becomes a lead-in line and numbered items. Pure text rules. Only ordinal markers count
/// ("first", "1st", "firstly", "number one"); cardinal "one... two..." is too common in ordinary
/// prose to convert without the model.
enum SpokenListFormatter {
    static let maximumItems = 10
    static let maximumWordsPerItem = 25

    private static let ordinalWords = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"
    ]
    private static let ordinalAdverbs = [
        "firstly", "secondly", "thirdly", "fourthly", "fifthly",
        "sixthly", "seventhly", "eighthly", "ninthly", "tenthly"
    ]
    private static let cardinalWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinalSuffixes = ["st", "nd", "rd", "th", "th", "th", "th", "th", "th", "th"]

    /// A marker right after one of these words is part of a phrase ("the first time",
    /// "at first", "a second"), not the start of a list item.
    private static let blockingPreviousWords: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "its", "this", "that",
        "these", "those", "every", "each", "at", "one", "per", "very"
    ]

    /// The numbered-list rendering of `text`, or nil when it holds fewer than two counted items in
    /// order, already spans several lines, or any item runs longer than a list item should.
    static func numberedList(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }

        var markers: [Range<String.Index>] = []
        var searchStart = trimmed.startIndex
        for position in 1...maximumItems {
            guard let range = marker(position: position, in: trimmed, from: searchStart) else { break }
            markers.append(range)
            searchStart = range.upperBound
        }
        guard markers.count >= 2 else { return nil }

        var items: [String] = []
        var trailingText = ""
        for (index, marker) in markers.enumerated() {
            let isLast = index == markers.count - 1
            var body = String(trimmed[marker.upperBound..<(isLast ? trimmed.endIndex : markers[index + 1].lowerBound)])
            if isLast, let end = body.range(of: #"[.!?]\s+"#, options: .regularExpression) {
                // Text after the last item's sentence is not part of the list.
                trailingText = String(body[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                body = String(body[..<end.lowerBound])
            }
            let item = cleanedItem(body)
            guard !item.isEmpty, item.split(whereSeparator: \.isWhitespace).count <= maximumWordsPerItem else {
                return nil
            }
            items.append(item)
        }

        var lines: [String] = []
        let leadIn = cleanedLeadIn(String(trimmed[..<markers[0].lowerBound]))
        if !leadIn.isEmpty {
            lines.append(leadIn + ":")
        }
        for (index, item) in items.enumerated() {
            lines.append("\(index + 1). \(item)")
        }
        if !trailingText.isEmpty {
            lines.append("")
            lines.append(trailingText)
        }
        return lines.joined(separator: "\n")
    }

    /// The first marker for `position` (1-based) at or after `start` that is not part of a phrase.
    private static func marker(position: Int, in text: String, from start: String.Index) -> Range<String.Index>? {
        let index = position - 1
        let alternatives = [
            #"number\s+(?:"# + cardinalWords[index] + "|\(position))",
            ordinalAdverbs[index],
            ordinalWords[index],
            "\(position)" + ordinalSuffixes[index]
        ]
        let pattern = #"(?i)(?<![\p{L}\p{N}_])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#
        var searchStart = start
        while searchStart < text.endIndex,
              let range = text.range(of: pattern, options: .regularExpression, range: searchStart..<text.endIndex) {
            if !isPartOfPhrase(text[..<range.lowerBound]) {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// True when the word directly before the marker, separated only by spaces, makes it a phrase.
    private static func isPartOfPhrase(_ prefix: Substring) -> Bool {
        let beforeMarker = prefix.reversed().drop { $0 == " " || $0 == "\t" }
        guard let last = beforeMarker.first, last.isLetter else { return false }
        let previousWord = String(beforeMarker.prefix { $0.isLetter }.reversed()).lowercased()
        return blockingPreviousWords.contains(previousWord)
    }

    private static let edgePunctuation = CharacterSet(charactersIn: ",;:.-–—")

    private static func cleanedItem(_ body: String) -> String {
        var item = body.trimmingCharacters(in: .whitespaces)
        item = String(item.drop { $0.unicodeScalars.allSatisfy { edgePunctuation.contains($0) } || $0 == " " })
        while true {
            let before = item
            item = item.trimmingCharacters(in: CharacterSet.whitespaces.union(edgePunctuation))
            for conjunction in [" and then", " and", " then"] where item.lowercased().hasSuffix(conjunction) {
                item.removeLast(conjunction.count)
            }
            if item == before { break }
        }
        return capitalizingFirstWord(item)
    }

    private static func cleanedLeadIn(_ text: String) -> String {
        let leadIn = text.trimmingCharacters(in: CharacterSet.whitespaces.union(edgePunctuation))
        return capitalizingFirstWord(leadIn)
    }

    /// Capitalizes a first word written entirely in lowercase; "iPhone" or "macOS" stay as they are.
    private static func capitalizingFirstWord(_ text: String) -> String {
        guard let first = text.first else { return text }
        let firstWord = text.prefix { !$0.isWhitespace }
        guard first.isLowercase, firstWord.allSatisfy({ !$0.isUppercase }) else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
