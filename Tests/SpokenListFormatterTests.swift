import Foundation

enum SpokenListFormatterTests {
    static func run() {
        testCountedListsBecomeNumberedLines()
        testPhrasesAndProseAreLeftAlone()
        testItemCleanup()
    }

    private static func testCountedListsBecomeNumberedLines() {
        let grocery = "Things to buy:\n1. Milk\n2. Eggs\n3. Bread"
        let cases: [(String, String)] = [
            // The first test pass: ordinal words the model left as prose.
            ("Things to buy first milk second eggs third bread", grocery),
            ("things to buy, first milk, second eggs, and third bread.", grocery),
            // Deepgram's smart formatting can turn ordinal words into digits.
            ("Things to buy: 1st milk, 2nd eggs, 3rd bread.", grocery),
            ("Number one fix the bug, number two ship it.", "1. Fix the bug\n2. Ship it"),
            ("Firstly we test, secondly we ship.", "1. We test\n2. We ship"),
            ("The steps are first plan, second build", "The steps are:\n1. Plan\n2. Build"),
            ("Pack first a charger second the passport. Then lock the door.",
             "Pack:\n1. A charger\n2. The passport\n\nThen lock the door.")
        ]
        for (input, expected) in cases {
            TestSupport.expectEqual(SpokenListFormatter.numberedList(from: input), expected)
        }
    }

    private static func testPhrasesAndProseAreLeftAlone() {
        for input in [
            "This is the first time I tried it, second guessing myself.",
            "At first it failed, then it worked.",
            "First, let's talk about the plan.",
            "Second milk first eggs.",
            "Buy one milk and two eggs.",
            "Things to buy:\n1. Milk\n2. Eggs",
            "",
            "First " + String(repeating: "word ", count: 30) + "second item"
        ] {
            TestSupport.expectEqual(SpokenListFormatter.numberedList(from: input), nil)
        }
    }

    private static func testItemCleanup() {
        TestSupport.expectEqual(
            SpokenListFormatter.numberedList(from: "Gifts first iPhone case, second macOS book"),
            "Gifts:\n1. iPhone case\n2. macOS book"
        )
        TestSupport.expectEqual(
            SpokenListFormatter.numberedList(from: "first: wake up and then second: run"),
            "1. Wake up\n2. Run"
        )
    }
}
