import Foundation

/// Synthetic, invented phrases only (the lab's case tables, with invented names), a small
/// synthetic lexicon and one fast check of the bundled word list. No AppState, no I/O beyond
/// reading the repository's resource file.
enum CorrectionLearnerTests {
    private typealias Learner = CorrectionLearner

    static func run() {
        testBaseCases()
        testMemoCases()
        testRefutingPairs()
        testAdversarialGates()
        testTieBreakInvariance()
        testStutterFuzz()
        testPhonetics()
        testFilters()
        testSettledTermsAreNotRelearnedInPart()
        testLearnedRulesRevert()
        testBounds()
        testWithoutEditGates()
        testSentenceStartNames()
        testWordListParsing()
        testBundledWordListResource()
    }

    // MARK: Fixtures

    /// EverydayWords plus 50 known words and 12 first names: on every case below this gives
    /// the same outcomes as the bundled SCOWL list and /usr/share/dict/propernames.
    struct TestLexicon: LearningLexicon {
        static let knownOnly: Set<String> = [
            "ai", "ant", "asp", "audit", "chow", "codex", "com", "cooper", "copilot", "dashboard",
            "deploy", "docs", "email", "ember", "flights", "gram", "hashtag", "i", "ie", "john",
            "la", "lang", "llama", "login", "max", "mellow", "multi", "ok", "p", "pane",
            "parser", "ping", "replication", "setup", "sonnet", "sql", "tar", "template", "they're", "ts",
            "um", "vibe", "vs", "website", "whisper", "windsurf", "www", "x", "y", "zed",
        ]
        static let firstNames: Set<String> = [
            "bob", "claude", "jason", "john", "jon", "max", "no", "old", "ping", "real", "the", "think",
        ]

        func isEveryday(_ lowercased: String) -> Bool { EverydayWords.contains(lowercased) }
        func isKnown(_ lowercased: String) -> Bool { Self.knownOnly.contains(lowercased) || EverydayWords.contains(lowercased) }
        func isFirstName(_ lowercased: String) -> Bool { Self.firstNames.contains(lowercased) }
    }

    static let lexicon = TestLexicon()

    private struct Case {
        let name: String
        let pasted: String
        let final: String
        let expect: String
        var confidences: [String: Double] = [:]
        var manual: Set<String> = []
        var learned: Set<String> = []
        var tombstoned: Set<String> = []
    }

    private static func learn(
        _ pasted: String,
        _ final: String,
        confidences: [String: Double] = [:],
        manual: Set<String> = [],
        learned: Set<String> = [],
        rules: [(heard: String, term: String)] = [],
        tombstoned: Set<String> = [],
        tieBreak: Learner.TieBreak = .earliest,
        lexicon: LearningLexicon = lexicon
    ) -> Learner.Outcome {
        Learner.learn(
            pasted: pasted,
            final: final,
            lexicon: lexicon,
            confidences: confidences,
            manualTerms: manual,
            learnedTerms: learned,
            learnedRules: Set(rules.map { Learner.ruleKey(heard: $0.heard, term: $0.term) }),
            isTombstoned: { tombstoned.contains($0) },
            tieBreak: tieBreak
        )
    }

    private static func learn(_ testCase: Case, tieBreak: Learner.TieBreak) -> Learner.Outcome {
        learn(
            testCase.pasted,
            testCase.final,
            confidences: testCase.confidences,
            manual: testCase.manual,
            learned: testCase.learned,
            tombstoned: testCase.tombstoned,
            tieBreak: tieBreak
        )
    }

    /// "heard->term:strong|weak:now|later|term" per candidate joined by "; ", "REVERT h->t",
    /// or "nothing".
    private static func fmt(_ outcome: Learner.Outcome) -> String {
        switch outcome {
        case .nothing:
            return "nothing"
        case .learned(let candidates):
            return candidates.map { candidate in
                if candidate.isRevert { return "REVERT \(candidate.heard)->\(candidate.term)" }
                let rule = candidate.ruleNow ? "now" : candidate.ruleLater ? "later" : "term"
                return "\(candidate.heard)->\(candidate.term):\(candidate.strength.rawValue):\(rule)"
            }.joined(separator: "; ")
        }
    }

    private static func reason(_ outcome: Learner.Outcome) -> Learner.Reason? {
        if case .nothing(let reason) = outcome { return reason }
        return nil
    }

    private static func expectCases(_ cases: [Case]) {
        for testCase in cases {
            for tieBreak in [Learner.TieBreak.earliest, .latest] {
                let got = fmt(learn(testCase, tieBreak: tieBreak))
                TestSupport.expect(
                    got == testCase.expect,
                    "\(testCase.name) (\(tieBreak)): expected \(testCase.expect), got \(got)"
                )
            }
        }
    }

    // MARK: Case tables (learning_algorithms.md §10 and memo 2.13, synthetic)

    private static let baseCases: [Case] = [
        // Claude Code prompts
        Case(name: "C1 single mishearing of a product name", pasted: "ask cloud to refactor the parser", final: "ask Claude to refactor the parser", expect: "cloud->Claude:strong:term"),
        Case(name: "C2 two-word product, case-only neighbour absorbed", pasted: "open cloud code and run the tests", final: "open Claude Code and run the tests", expect: "cloud code->Claude Code:strong:later"),
        Case(name: "C3 merge of split product name", pasted: "check the deep gram socket code", final: "check the Deepgram socket code", expect: "deep gram->Deepgram:strong:later"),
        Case(name: "C4 non-word heard side gets a rule at once", pasted: "deploy it to versel tonight", final: "deploy it to Vercel tonight", expect: "versel->Vercel:strong:now"),
        Case(name: "C5 merge into lowercase compound", pasted: "make a new work tree for this branch", final: "make a new worktree for this branch", expect: "work tree->worktree:strong:later"),
        Case(name: "C6 CamelCase identifier from everyday words: term only", pasted: "read the app state file first", final: "read the AppState file first", expect: "app state->AppState:strong:term"),
        Case(name: "C7 file name with spoken dot", pasted: "open use auth dot ts and fix it", final: "open useAuth.ts and fix it", expect: "use auth dot ts->useAuth.ts:strong:term"),
        Case(name: "C8 acronym heard as a name", pasted: "parse the Jason response", final: "parse the JSON response", expect: "Jason->JSON:strong:term"),
        Case(name: "C9 acronym heard as a word", pasted: "write a sequel query for that", final: "write a SQL query for that", expect: "sequel->SQL:strong:term"),
        Case(name: "C10 rewording is not learned", pasted: "fix the bug in the parser", final: "fix the issue in the parser", expect: "nothing"),
        Case(name: "C11 similar known words (rewrite)", pasted: "I renamed the file", final: "I removed the file", expect: "nothing"),
        Case(name: "C12 one fix among a rewrite of another word", pasted: "I was drafting the versel config now", final: "I was editing the Vercel config now", expect: "versel->Vercel:strong:now"),
        Case(name: "C13 typed suffix around dictation is ignored", pasted: "the slow one is kwen", final: "the slow one is Qwen thanks", expect: "kwen->Qwen:strong:now"),
        Case(name: "C14 text typed before dictation is ignored", pasted: "kwen tokenizer is broken", final: "hey, Qwen tokenizer is broken", expect: "kwen->Qwen:strong:now"),
        Case(name: "C15 long rewrite", pasted: "we should ship it today", final: "please reconsider the whole plan before shipping anything", expect: "nothing"),
        Case(name: "C16 pure insertion", pasted: "make it faster", final: "make it much faster please", expect: "nothing"),
        Case(name: "C17 pure deletion of filler", pasted: "so um fix the tests", final: "fix the tests", expect: "nothing"),
        Case(name: "C18 punctuation only", pasted: "fix the tests", final: "fix the tests.", expect: "nothing"),
        Case(name: "C19 sentence-start capital is not evidence", pasted: "done. their tests pass", final: "done. There tests pass", expect: "nothing"),
        Case(name: "C20 homophone of everyday words", pasted: "put it over their", final: "put it over there", expect: "nothing"),
        Case(name: "C21 inflection", pasted: "it run the tests", final: "it ran the tests", expect: "nothing"),
        Case(name: "C22 already a known term", pasted: "deploy it to versel tonight", final: "deploy it to Vercel tonight", expect: "nothing", manual: ["vercel"]),
        Case(name: "C23 tombstoned term", pasted: "deploy it to versel tonight", final: "deploy it to Vercel tonight", expect: "nothing", tombstoned: ["vercel"]),
        Case(name: "C24 secret typed over a word", pasted: "use the key here", final: "use the sk-ant-FAKE0example0000 here", expect: "nothing"),
        Case(name: "C25 number change", pasted: "set the timeout to 30 seconds", final: "set the timeout to 45 seconds", expect: "nothing"),
        Case(name: "C26 local name the ASR mangled", pasted: "ask dravish of to review", final: "ask Dravishov to review", expect: "dravish of->Dravishov:strong:now"),
        Case(name: "C27 two fixes side by side", pasted: "use super base with post gress", final: "use Supabase with Postgres", expect: "super base->Supabase:strong:later; post gress->Postgres:strong:now"),
        Case(name: "C28 Kubernetes far spelling, near sound", pasted: "deploy to cooper netties", final: "deploy to Kubernetes", expect: "cooper netties->Kubernetes:strong:now"),
        Case(name: "C29 ordinary-word fix is not vocabulary", pasted: "please add it the change log", final: "please audit the change log", expect: "nothing"),
        Case(name: "C30 low ASR confidence promotes a weak case fix", pasted: "ask anthropic support", final: "ask Anthropic support", expect: "anthropic->Anthropic:strong:term", confidences: ["anthropic": 0.48]),
        Case(name: "C31 ordinary-word swap stays out even with confidence", pasted: "use the fast path", final: "use the quick path", expect: "nothing", confidences: ["fast": 0.99]),
        Case(name: "C32 case-only to code shape", pasted: "push it to github", final: "push it to GitHub", expect: "github->GitHub:strong:term"),
        Case(name: "C33 case-only proper name mid-sentence is weak", pasted: "ask anthropic support", final: "ask Anthropic support", expect: "anthropic->Anthropic:weak:term"),
        Case(name: "C34 short case fix is style", pasted: "then i think it works", final: "then I think it works", expect: "nothing"),
        // ChatGPT prompts
        Case(name: "G1 product with digits", pasted: "compare GPT for oh with Claude", final: "compare GPT-4o with Claude", expect: "GPT for oh->GPT-4o:strong:later"),
        Case(name: "G2 merge spoken dotted name", pasted: "explain next JS routing", final: "explain Next.js routing", expect: "next JS->Next.js:strong:later"),
        Case(name: "G3 email address is skipped", pasted: "email dravish at example dot com", final: "email dravish@example.com", expect: "nothing"),
        Case(name: "G4 URL is skipped", pasted: "summarize vercel dot com pricing", final: "summarize vercel.com pricing", expect: "nothing"),
        // Google searches
        Case(name: "S1 lowercase search fix of non-word", pasted: "versel pricing", final: "vercel pricing", expect: "versel->vercel:strong:now"),
        Case(name: "S2 whole short query replaced", pasted: "best pizza near me", final: "cheap flights to tokyo", expect: "nothing"),
        Case(name: "S3 search query merge", pasted: "lang chain docs", final: "langchain docs", expect: "lang chain->langchain:strong:later"),
        Case(name: "S4 search lowercase of common word", pasted: "Cursor pricing", final: "cursor pricing", expect: "nothing"),
        Case(name: "S5 search word swap", pasted: "why is my build slow", final: "what is my build slow", expect: "nothing"),
        Case(name: "S6 search adds a word", pasted: "wispr flow pricing", final: "wispr flow pricing 2026", expect: "nothing"),
        Case(name: "S7 search fix of phonetic product", pasted: "whisper flow alternatives", final: "wispr flow alternatives", expect: "whisper->wispr:strong:term"),
        Case(name: "C35 known product swapped, confident ASR: weak", pasted: "use React for the UI", final: "use Preact for the UI", expect: "React->Preact:weak:term", confidences: ["react": 0.98]),
        Case(name: "C36 same swap without confidence: strong", pasted: "use React for the UI", final: "use Preact for the UI", expect: "React->Preact:strong:term"),
        Case(name: "C37 learned term over-applied, user restores the word", pasted: "store it in Claude storage", final: "store it in cloud storage", expect: "REVERT Claude->cloud", learned: ["claude"]),
        Case(name: "C38 cleanup LLM fix accepted (raw vs pasted)", pasted: "tell cloud code to run lint", final: "tell Claude Code to run lint", expect: "cloud code->Claude Code:strong:later"),
        Case(name: "C39 change of mind between products", pasted: "move it to Postgres", final: "move it to SQLite", expect: "nothing"),
        Case(name: "C40 several fixes in a long prompt", pasted: "ask cloud to use super base and versel and post gress", final: "ask Claude to use Supabase and Vercel and Postgres", expect: "cloud->Claude:strong:term; super base->Supabase:strong:later; versel->Vercel:strong:now; post gress->Postgres:strong:now"),
        Case(name: "C41 change of mind between similar-length products", pasted: "write the tests with Jest", final: "write the tests with Vitest", expect: "nothing"),
        Case(name: "C42 change of mind React to Preact, confident", pasted: "port it to React today", final: "port it to Preact today", expect: "React->Preact:weak:term", confidences: ["react": 0.97]),
        Case(name: "S9 search query, user fixes a name typed by FreeFlow", pasted: "bar well family tree", final: "barwell family tree", expect: "bar well->barwell:strong:later"),
        Case(name: "S10 search query fix case-only lowercase", pasted: "GitHub copilot pricing", final: "github copilot pricing", expect: "nothing"),
        Case(name: "G5 model name with version", pasted: "is cloud sonnet five good", final: "is Claude Sonnet 5 good", expect: "cloud sonnet five->Claude Sonnet 5:strong:later"),
        Case(name: "S8 common first name changed", pasted: "john smith github", final: "jon smith github", expect: "nothing"),
    ]

    private static let memoCases: [Case] = [
        Case(name: "M1 product swap away from a vocabulary term is never learned", pasted: "try it with Grok today", final: "try it with Groq today", expect: "nothing", manual: ["grok"]),
        Case(name: "M2 sound-alike product swap without vocabulary", pasted: "try it with Grok today", final: "try it with Groq today", expect: "Grok->Groq:strong:later"),
        Case(name: "M3 same swap, confident ASR: weak", pasted: "try it with Grok today", final: "try it with Groq today", expect: "Grok->Groq:weak:later", confidences: ["grok": 0.97]),
        Case(name: "M4 affix content edit is not a fix", pasted: "check the deep gram socket", final: "check the Deepgram websocket", expect: "deep gram->Deepgram:strong:later"),
        Case(name: "M5 stutter after the term is peeled", pasted: "ask cloud to to refactor the parser", final: "ask Claude to refactor the parser", expect: "cloud->Claude:strong:term"),
        Case(name: "M6 stutter before the term is peeled", pasted: "is the the kwen model fast", final: "is the Qwen model fast", expect: "kwen->Qwen:strong:now"),
        Case(name: "M7 no case absorption across a sentence end", pasted: "ask cloud. Then run the tests", final: "ask Claude, then run the tests", expect: "cloud->Claude:strong:term"),
        Case(name: "M8 two products side by side split into two", pasted: "use versel kwen today", final: "use Vercel Qwen today", expect: "versel->Vercel:strong:now; kwen->Qwen:strong:now"),
        Case(name: "M9 pasted word deleted next to the fix (trailing)", pasted: "deploy it to versel tonight", final: "deploy it to Vercel", expect: "versel->Vercel:strong:now"),
        Case(name: "M10 pasted word deleted next to the fix (leading)", pasted: "hey kwen tokenizer is broken", final: "Qwen tokenizer is broken", expect: "kwen->Qwen:strong:now"),
        Case(name: "M11 sentence split inside a hunk", pasted: "use super base. Post gress later", final: "use Supabase. Postgres later", expect: "super base->Supabase:strong:later; Post gress->Postgres:strong:now"),
        Case(name: "M12 title case of a heading is style, not vocabulary", pasted: "project plan for the new dashboard and login flow", final: "Project Plan for the New Dashboard and Login Flow", expect: "nothing"),
        Case(name: "M13 five real fixes keep four, strong first", pasted: "ask cloud to use super base and versel and post gress and kwen", final: "ask Claude to use Supabase and Vercel and Postgres and Qwen", expect: "cloud->Claude:strong:term; super base->Supabase:strong:later; versel->Vercel:strong:now; post gress->Postgres:strong:now"),
        Case(name: "M14 rewrite with one non-word fix", pasted: "versel and ships and runs and rests and eats", final: "Vercel and sails and walks and sleeps and drinks", expect: "nothing"),
        Case(name: "M15 markdown bold added by the composer", pasted: "use the wispr flow api", final: "use the **Wispr Flow** api", expect: "wispr flow->Wispr Flow:weak:term"),
        Case(name: "M16 search: lowercase phonetic fix", pasted: "whisper flow pricing", final: "wispr flow pricing", expect: "whisper->wispr:strong:term"),
        Case(name: "M17 search: append is not a fix", pasted: "claude code", final: "claude code vs cursor", expect: "nothing"),
        Case(name: "M18 search: change of intent", pasted: "cursor vs windsurf", final: "cursor vs zed", expect: "nothing"),
        Case(name: "M19 dictated identifiers x4", pasted: "rename user id to account id and order id to purchase id", final: "rename userId to accountId and orderId to purchaseId", expect: "user id->userId:strong:term; account id->accountId:strong:term; order id->orderId:strong:term; purchase id->purchaseId:strong:term"),
    ]

    /// The verification's refuting pairs with their expected outcomes.
    private static let refutingPairs: [(pasted: String, final: String, expect: String)] = [
        ("deploy it to versel tonight", "deploy it to Vercel", "versel->Vercel:strong:now"),
        ("ask cloud please to refactor the parser", "ask Claude to refactor the parser", "cloud->Claude:strong:term"),
        ("hey kwen tokenizer is broken", "Qwen tokenizer is broken", "kwen->Qwen:strong:now"),
        ("so I opened cloud code", "I opened Claude Code", "cloud code->Claude Code:strong:later"),
        ("check the deep gram socket", "check the Deepgram websocket", "deep gram->Deepgram:strong:later"),
        ("push it to github and ask cloud", "push it to GitHub and ask Claude", "github->GitHub:strong:term; cloud->Claude:strong:term"),
        ("use super base. Post gress later", "use Supabase. Postgres later", "super base->Supabase:strong:later; Post gress->Postgres:strong:now"),
        ("ask cloud to to refactor the parser", "ask Claude to refactor the parser", "cloud->Claude:strong:term"),
        ("open cloud code code and run the tests", "open Claude Code and run the tests", "cloud code->Claude Code:strong:later"),
        ("deploy it to versel the the config is ready", "deploy it to Vercel the config is ready", "versel->Vercel:strong:now"),
        ("check the deep gram the the socket", "check the Deepgram the socket", "deep gram->Deepgram:strong:later"),
        ("use super base and and post gress", "use Supabase and Postgres", "super base->Supabase:strong:later; post gress->Postgres:strong:now"),
        ("ask cloud. Then run the tests", "ask Claude, then run the tests", "cloud->Claude:strong:term"),
        ("use versel kwen today", "use Vercel Qwen today", "versel->Vercel:strong:now; kwen->Qwen:strong:now"),
        ("is the the kwen model fast", "is the Qwen model fast", "kwen->Qwen:strong:now"),
        ("tell cloud to to fix it", "tell Claude to fix it", "cloud->Claude:strong:term"),
    ]

    /// Gate cases: Title Case, grammar polish, product lists, identifier restyling.
    private static let adversarialCases: [Case] = [
        Case(name: "T1 title-case a search heading", pasted: "how to set up postgres replication on kubernetes", final: "How to Set Up Postgres Replication on Kubernetes", expect: "nothing"),
        Case(name: "T2 title-case chat heading", pasted: "project plan for the new dashboard and login flow", final: "Project Plan for the New Dashboard and Login Flow", expect: "nothing"),
        Case(name: "T3 grammar polish + product change of mind", pasted: "I run the test and fix the parser then use react", final: "I ran the tests and fixed the parsers then use Preact", expect: "nothing"),
        Case(name: "T4 dictated words -> identifiers x4", pasted: "rename user id to account id and order id to purchase id", final: "rename userId to accountId and orderId to purchaseId", expect: "user id->userId:strong:term; account id->accountId:strong:term; order id->orderId:strong:term; purchase id->purchaseId:strong:term"),
        Case(name: "T5 homophone cleanup", pasted: "their going to fix it to and right the tests for there team", final: "they're going to fix it too and write the tests for their team", expect: "nothing"),
        Case(name: "T6 five fixes keep four", pasted: "ask cloud to use super base and versel and post gress and kwen", final: "ask Claude to use Supabase and Vercel and Postgres and Qwen", expect: "cloud->Claude:strong:term; super base->Supabase:strong:later; versel->Vercel:strong:now; post gress->Postgres:strong:now"),
        Case(name: "T7 short prompt, three two-word merges", pasted: "use lang chain with deep gram and super base", final: "use LangChain with Deepgram and Supabase", expect: "lang chain->LangChain:strong:term; deep gram->Deepgram:strong:later; super base->Supabase:strong:later"),
        Case(name: "T8 stack swap change of mind, sound-alike", pasted: "build it with react and redis and render and jest", final: "build it with Preact and Redux and Railway and Vitest", expect: "react->Preact:weak:term"),
        Case(name: "T9 title-case product list", pasted: "compare cursor windsurf zed and copilot for teams", final: "Compare Cursor Windsurf Zed and Copilot for Teams", expect: "nothing"),
        Case(name: "T10 sentence case and capitalized names", pasted: "tell dravish of and anthropic and open ai about the deep gram bug", final: "Tell Dravishov and Anthropic and OpenAI about the Deepgram bug", expect: "dravish of->Dravishov:strong:now; anthropic->Anthropic:weak:term; open ai->OpenAI:strong:term; deep gram->Deepgram:strong:later"),
        Case(name: "T11 user restyles to snake_case", pasted: "set max tokens and top p and stop sequences in the request", final: "set max_tokens and top_p and stop_sequences in the request", expect: "max tokens->max_tokens:strong:term; top p->top_p:strong:term; stop sequences->stop_sequences:strong:term"),
        Case(name: "T12 hyphenation and compounding cleanup", pasted: "a real time multi step set up for front end and back end work", final: "a realtime multistep setup for frontend and backend work", expect: "nothing"),
    ]

    /// External agreement inputs (localvoxtral and kotoba styles, invented text): used for the
    /// tie-break invariance check only.
    private static let externalInputs: [(String, String)] = [
        ("can you check why Coin 3.6 is slow", "can you check why Qwen 3.6 is slow"),
        ("the Kuen tokenizer drops the BOS", "the Qwen tokenizer drops the BOS"),
        ("please fix the kwen tokenizer", "please fix the Qwen tokenizer"),
        ("read the tool input field first", "read the toolInput field first"),
        ("hook the session start event", "hook the SessionStart event"),
        ("we rent an H100.", "we rent an H200."),
        ("is it kwen, or llama", "is it Qwen, or llama"),
        ("fix the kwen tokenizer", "context: see #412\nfix the Qwen tokenizer and run the tests"),
        ("vibe runs the hooks", "Vibe runs the hooks"),
        ("so um please fix the kwen tokenizer", "please fix the Qwen tokenizer"),
        ("click the terminal pain", "click the terminal pane"),
        ("fix the bug\nthen commit", "fix the bug\nThen commit"),
        ("fix the bug then kwen", "fix the bug\nthen Qwen"),
        ("that's what I was doing. Usually it works", "that's what I was doing.Usually it works"),
        ("it was a mistake, So revert it", "it was a mistake,So revert it"),
        ("what I was doing, usually it works", "what I was doing. Usually it works"),
        ("call os exit with one", "call os.Exit with one"),
        ("edit the package. json file", "edit the package.json file"),
        ("rename foo dot bar", "rename foo.Bar"),
        ("it is ok now", "it is OK now"),
        ("then vibe runs the hooks", "then Vibe runs the hooks"),
        ("use a flag eg the verbose one", "use a flag e.g. the verbose one"),
        ("the old one ie the first", "the old one i.e. the first"),
        ("read x dot y from it", "read x.y from it"),
        ("make the Kuen server faster", "make the Qwen server quicker"),
        ("can you check why the kwen server is slow today", "never mind, just restart the Qwen server"),
        ("fix the kwen tokenizer", "something else entirely"),
        ("so basically what I want is for you to fix the kwen tokenizer now", "what I want is you to fix the Qwen tokenizer"),
        ("run the one two three four five tests now", "run the OneTwoThreeFourFive tests now"),
        ("rename the order ID column", "rename the order_id column"),
        ("use the order ID field", "use the `order_id` field"),
        ("the ember package is great", "the embra package is great"),
        ("call me at Mellow.", "call me at Marlow."),
        ("post in hashtag team ops now", "post in #team-ops now"),
        ("dinner with Orlina tonight", "dinner with Orlena tonight"),
        ("is the calender ready", "is the Calendar ready"),
        ("ask the tar vee no team", "ask the Tarvino team"),
        ("open the ZenTail website", "open the Zentyl template"),
        ("talk to sea dex or so", "talk to Codex"),
        ("an ssl-based check", "an access-based check"),
        ("done</li> <li>next", "done - next"),
        ("ping bob at example dot org", "ping bob@example.org"),
        ("open www dot vercel dot com", "open www.vercel.com"),
        ("run it on node js today", "run it on Node.js today"),
        ("build it in asp dot net", "build it in ASP.NET"),
        ("so um we ship it", "so we ship it"),
        ("we  ship\nit", "we ship it"),
        ("about 2.5 people", "about 25 people"),
        ("is it ten.", "is it ten?"),
        ("Tavia.", "Orlena for the meeting."),
        ("open the docs slash api", "open the docs/api"),
        ("versel and versel", "Vercel and Vercel"),
    ]

    // MARK: Tests

    private static func testBaseCases() {
        TestSupport.expectEqual(baseCases.count, 57)
        expectCases(baseCases)
    }

    private static func testMemoCases() {
        TestSupport.expectEqual(memoCases.count, 19)
        expectCases(memoCases)
        // M13: exactly four kept, strong first.
        if case .learned(let candidates) = learn(memoCases[12], tieBreak: .earliest) {
            TestSupport.expectEqual(candidates.count, Learner.maxCandidates)
            TestSupport.expect(candidates.allSatisfy { $0.strength == .strong }, "M13 keeps the strong candidates")
        } else {
            TestSupport.expect(false, "M13 learns four candidates")
        }
        // M1 is protected by the manual vocabulary; a learned "grok" protects it too.
        TestSupport.expectEqual(reason(learn("try it with Grok today", "try it with Groq today", manual: ["grok"])), .protectedTerm)
        TestSupport.expectEqual(reason(learn("try it with Grok today", "try it with Groq today", learned: ["grok"])), .protectedTerm)
        // A learned term seen again still reaches the store (only manual terms are already known).
        TestSupport.expectEqual(
            fmt(learn("deploy it to versel tonight", "deploy it to Vercel tonight", learned: ["vercel"])),
            "versel->Vercel:strong:now"
        )
    }

    private static func testRefutingPairs() {
        for pair in refutingPairs {
            for tieBreak in [Learner.TieBreak.earliest, .latest] {
                let got = fmt(learn(pair.pasted, pair.final, tieBreak: tieBreak))
                TestSupport.expect(got == pair.expect, "\(pair.pasted) (\(tieBreak)): expected \(pair.expect), got \(got)")
            }
        }
    }

    private static func testAdversarialGates() {
        expectCases(adversarialCases)
        TestSupport.expectEqual(reason(learn(adversarialCases[1], tieBreak: .earliest)), .rewrite)
        TestSupport.expectEqual(reason(learn(adversarialCases[8], tieBreak: .earliest)), .rewrite)
    }

    /// The two LCS tie-breaks give the same outcome (codes included) on every input.
    private static func testTieBreakInvariance() {
        var inputs = (baseCases + memoCases + adversarialCases).map { ($0.pasted, $0.final) }
        inputs += refutingPairs.map { ($0.pasted, $0.final) }
        inputs += externalInputs
        for (pasted, final) in inputs {
            let earliest = learn(pasted, final, tieBreak: .earliest)
            let latest = learn(pasted, final, tieBreak: .latest)
            TestSupport.expect(earliest == latest, "tie-break changed the outcome of \(pasted) -> \(final)")
        }
    }

    /// The lab's seeded generator: random filler with one fix inserted, clean, with a stutter
    /// after the fix and with one before it. Every edit must learn exactly the inserted pair.
    private static func testStutterFuzz() {
        struct LCG: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state
            }
        }
        let filler = ["the", "the", "to", "it", "and", "run", "tests", "code", "fix", "then", "check", "file"]
        let fixes: [([String], [String])] = [
            (["versel"], ["Vercel"]), (["kwen"], ["Qwen"]), (["deep", "gram"], ["Deepgram"]),
            (["cloud"], ["Claude"]), (["super", "base"], ["Supabase"]), (["post", "gress"], ["Postgres"]),
        ]
        for mode in 0..<3 {
            for tieBreak in [Learner.TieBreak.earliest, .latest] {
                var generator = LCG(state: 11)
                for _ in 0..<150 {
                    let count = Int.random(in: 5...14, using: &generator)
                    let words = (0..<count).map { _ in filler[Int.random(in: 0..<filler.count, using: &generator)] }
                    let fix = fixes[Int.random(in: 0..<fixes.count, using: &generator)]
                    let at = Int.random(in: 1..<words.count, using: &generator)
                    var pasted = words
                    pasted.insert(contentsOf: fix.0, at: at)
                    var final = words
                    final.insert(contentsOf: fix.1, at: at)
                    if mode == 1 { pasted.insert(pasted[at + fix.0.count], at: at + fix.0.count) }
                    if mode == 2 { pasted.insert(pasted[at - 1], at: at - 1) }
                    let outcome = learn(pasted.joined(separator: " "), final.joined(separator: " "), tieBreak: tieBreak)
                    guard case .learned(let candidates) = outcome, candidates.count == 1 else {
                        TestSupport.expect(false, "fuzz mode \(mode) \(tieBreak): \(fmt(outcome)) for \(pasted) -> \(final)")
                        return
                    }
                    TestSupport.expectEqual(candidates[0].heard, fix.0.joined(separator: " "))
                    TestSupport.expectEqual(candidates[0].term, fix.1.joined(separator: " "))
                }
            }
        }
    }

    private static func testPhonetics() {
        let keys: [(String, String, String)] = [
            ("cloud", "Claude", "klt"), ("whisper", "Wispr", "wspr"), ("deep gram", "Deepgram", "tpkrm"),
            ("versel", "Vercel", "frsl"), ("get hub", "GitHub", "k0p"), ("kwen", "Qwen", "kn"),
            ("post gress", "Postgres", "pstkrs"),
        ]
        for (heard, term, key) in keys {
            TestSupport.expectEqual(LearningPhonetics.consonantKey(heard), key)
            TestSupport.expectEqual(LearningPhonetics.consonantKey(term), key)
            TestSupport.expect(LearningPhonetics.keysSoundAlike(heard, term), "\(heard) and \(term) share a key")
        }
        // Different keys; letter distance alone makes these sound alike.
        TestSupport.expectEqual(LearningPhonetics.consonantKey("super base"), "sprps")
        TestSupport.expectEqual(LearningPhonetics.consonantKey("Supabase"), "sps")
        TestSupport.expect(!LearningPhonetics.keysSoundAlike("super base", "Supabase"), "sprps and sps differ by two")
        TestSupport.expectApproximatelyEqual(LearningPhonetics.letterDistance("super base", "Supabase"), 2.0 / 9.0)
        TestSupport.expect(LearningPhonetics.soundsAlike("super base", "Supabase"), "super base sounds like Supabase")
        // A one-edit key difference counts only for keys of five or more letters.
        TestSupport.expectEqual(LearningPhonetics.consonantKey("Mellow"), "ml")
        TestSupport.expectEqual(LearningPhonetics.consonantKey("Marlow"), "mrl")
        TestSupport.expect(!LearningPhonetics.keysSoundAlike("Mellow", "Marlow"), "short keys need an exact match")
        TestSupport.expectEqual(LearningPhonetics.nearKeyMinimumLength, 5)
        // Spoken joiners drop only when there is more than one word.
        TestSupport.expectEqual(String(LearningPhonetics.letterKey("use auth dot ts")), "useauthts")
        TestSupport.expectEqual(String(LearningPhonetics.letterKey("dot")), "dot")

        let positives: [(String, String)] = [
            ("cloud", "Claude"), ("whisper", "Wispr"), ("deep gram", "Deepgram"), ("versel", "Vercel"),
            ("get hub", "GitHub"), ("kwen", "Qwen"), ("post gress", "Postgres"), ("super base", "Supabase"),
            ("cooper netties", "Kubernetes"), ("sequel", "SQL"), ("Jason", "JSON"), ("dravish of", "Dravishov"),
            ("Kuen", "Qwen"), ("coin", "Qwen"), ("bar well", "Barwell"), ("Mellow", "Marlow"),
            ("engine x", "nginx"), ("pie torch", "PyTorch"), ("olama", "Ollama"), ("ember", "embra"),
            ("add it", "audit"), ("x code", "Xcode"),
        ]
        let negatives: [(String, String)] = [
            ("bug", "issue"), ("why", "what"), ("renamed", "removed"), ("drafting", "editing"),
            ("shorter", "concise"), ("Postgres", "SQLite"), ("server", "host"), ("fast", "quick"),
            ("cheap", "best"), ("make", "write"), ("Claude", "ChatGPT"), ("React", "Vue"),
            ("fix", "debug"), ("file", "folder"), ("cloud", "AWS"), ("now", "today"),
            ("parser", "Prisma"), ("cache", "Kafka"), ("router", "Redis"),
        ]
        TestSupport.expectEqual(positives.count, 22)
        TestSupport.expectEqual(negatives.count, 19)
        for (a, b) in positives {
            TestSupport.expect(LearningPhonetics.soundsAlike(a, b), "\(a) should sound like \(b)")
        }
        for (a, b) in negatives {
            TestSupport.expect(!LearningPhonetics.soundsAlike(a, b), "\(a) should not sound like \(b)")
        }
    }

    private static func testFilters() {
        // Inputs that isolate each filter's own reason.
        TestSupport.expectEqual(reason(learn("open the vercel page", "open the vercel.com page")), .address)
        TestSupport.expectEqual(reason(learn("open the vercel page", "open the docs/api page")), .address)
        TestSupport.expectEqual(reason(learn("use the key here", "use the sk-ant-FAKE0example0000 here")), .secret)
        TestSupport.expectEqual(reason(learn("set it to 30 now", "set it to thirty now")), .number)
        TestSupport.expectEqual(reason(learn("set the timeout to 30 seconds", "set the timeout to 45 seconds")), .notWord)
        TestSupport.expectEqual(reason(learn("it run the tests", "it ran the tests")), .inflection)
        TestSupport.expectEqual(reason(learn("open the socket file", "open the websocket file")), .affixEdit)
        TestSupport.expectEqual(reason(learn("use the vercl plugin", "use the vercloud plugin")), .extension)
        TestSupport.expectEqual(reason(learn("it works. Then ship it", "it works.Then ship it")), .sentenceGlue)
        TestSupport.expectEqual(reason(learn("john smith github", "jon smith github")), .commonNameSwap)
        TestSupport.expectEqual(reason(learn("say hi to john today", "say hi to jon today")), .commonNameSwap)
        TestSupport.expectEqual(reason(learn("deploy it to versel tonight", "deploy it to Vercel tonight", tombstoned: ["vercel"])), .tombstoned)
        TestSupport.expectEqual(reason(learn("deploy it to versel tonight", "deploy it to Vercel tonight", manual: ["vercel"])), .alreadyKnownTerm)
        // Case and style changes are counted as style, never learned.
        TestSupport.expectEqual(reason(learn("then i think it works", "then I think it works")), .styleOrUnchanged)
        TestSupport.expectEqual(reason(learn("done. their tests pass", "done. There tests pass")), .everydayBothSides)
        TestSupport.expectEqual(reason(learn("fix the tests", "fix the tests.")), .styleOrUnchanged)
        // Whole-edit gates.
        TestSupport.expectEqual(reason(learn("email dravish at example dot com", "email dravish@example.com")), .rewrite)
        TestSupport.expectEqual(reason(learn("summarize vercel dot com pricing", "summarize vercel.com pricing")), .notThisDictation)
        TestSupport.expectEqual(reason(learn("best pizza near me", "cheap flights to tokyo")), .notFound)
        TestSupport.expectEqual(reason(learn("make it faster", "make it much faster please")), .contentEdit)
        TestSupport.expectEqual(reason(learn("move it to Postgres", "move it to SQLite")), .notSoundAlike)
        TestSupport.expectEqual(reason(learn("please add it the change log", "please audit the change log")), .ordinaryWords)
        TestSupport.expectEqual(reason(learn("versel and ships and runs and rests and eats", "Vercel and sails and walks and sleeps and drinks")), .rewording)
        // Code-shaped words.
        TestSupport.expect(Learner.isCodeShaped("GPT-4o"), "digits make a model name code-shaped")
        TestSupport.expect(Learner.isCodeShaped("useAuth"), "camelCase is code-shaped")
        TestSupport.expect(Learner.isCodeShaped("JSON"), "an acronym is code-shaped")
        TestSupport.expect(!Learner.isCodeShaped("Claude"), "a capitalized name is not code-shaped")
    }

    /// A removed (tombstoned) or manual term is a settled fix: the same fix never learns it
    /// again in part, as a phrase around it, or as a piece of a longer hunk.
    private static func testSettledTermsAreNotRelearnedInPart() {
        let settledCases: [Case] = [
            Case(name: "whole multi-word hunk removed", pasted: "open cloud code settings", final: "open Claude Code settings", expect: "nothing", tombstoned: ["claude code"]),
            Case(name: "whole multi-word hunk manual", pasted: "open cloud code settings", final: "open Claude Code settings", expect: "nothing", manual: ["claude code"]),
            Case(name: "model name removed", pasted: "is cloud sonnet five good", final: "is Claude Sonnet 5 good", expect: "nothing", tombstoned: ["claude sonnet 5"]),
            Case(name: "side-by-side pair removed: no phrase around it", pasted: "use versel kwen today", final: "use Vercel Qwen today", expect: "kwen->Qwen:strong:now", tombstoned: ["vercel"]),
            Case(name: "both pairs removed", pasted: "use versel kwen today", final: "use Vercel Qwen today", expect: "nothing", tombstoned: ["vercel", "qwen"]),
            Case(name: "removed phrase: no pair inside it", pasted: "use versel kwen today", final: "use Vercel Qwen today", expect: "nothing", tombstoned: ["vercel qwen"]),
            Case(name: "removed phrase inside a longer hunk", pasted: "ask cloud code now", final: "ask Claude Code please now", expect: "nothing", tombstoned: ["claude code"]),
            Case(name: "manual phrase inside a longer hunk", pasted: "then cloud code works", final: "then Claude Code really works", expect: "nothing", manual: ["claude code"]),
            Case(name: "removed partition term", pasted: "check the deep gram socket", final: "check the Deepgram websocket", expect: "nothing", tombstoned: ["deepgram"]),
            // A manual single word does not settle a longer term that contains it.
            Case(name: "manual word, new phrase", pasted: "open cloud code settings", final: "open Claude Code settings", expect: "cloud code->Claude Code:strong:later", manual: ["claude"]),
        ]
        expectCases(settledCases)
        TestSupport.expectEqual(learn("open cloud code settings", "open Claude Code settings", tombstoned: ["claude code"]), .nothing(.tombstoned))
        TestSupport.expectEqual(learn("open cloud code settings", "open Claude Code settings", manual: ["claude code"]), .nothing(.alreadyKnownTerm))
        TestSupport.expectEqual(learn("use versel kwen today", "use Vercel Qwen today", tombstoned: ["vercel", "qwen"]), .nothing(.tombstoned))
        TestSupport.expectEqual(learn("ask cloud code now", "ask Claude Code please now", tombstoned: ["claude code"]), .nothing(.tombstoned))
        TestSupport.expectEqual(learn("check the deep gram socket", "check the Deepgram websocket", tombstoned: ["deepgram"]), .nothing(.tombstoned))
        // Without the settled term these hunks do learn, so the cases above test the guard.
        TestSupport.expectEqual(fmt(learn("ask cloud code now", "ask Claude Code please now")), "cloud code->Claude Code:strong:later")
        TestSupport.expectEqual(fmt(learn("then cloud code works", "then Claude Code really works")), "cloud code->Claude Code:strong:later")
    }

    /// Changing a learned rule's output back to its heard phrase is a revert, whatever the
    /// heard phrase looks like; without the rule it stays protected.
    private static func testLearnedRulesRevert() {
        let reverts: [(pasted: String, final: String, term: String, heard: String)] = [
            ("try Groq today", "try Grok today", "Groq", "Grok"),
            ("ask Qwen about it", "ask kwen about it", "Qwen", "kwen"),
            ("use Postgres here", "use post gress here", "Postgres", "post gress"),
            ("deploy it to Vercel tonight", "deploy it to versel tonight", "Vercel", "versel"),
        ]
        for revert in reverts {
            let learned: Set<String> = [revert.term.lowercased()]
            for tieBreak in [Learner.TieBreak.earliest, .latest] {
                TestSupport.expectEqual(
                    fmt(learn(revert.pasted, revert.final, learned: learned, rules: [(revert.heard, revert.term)], tieBreak: tieBreak)),
                    "REVERT \(revert.term)->\(revert.heard)"
                )
            }
            TestSupport.expectEqual(reason(learn(revert.pasted, revert.final, learned: learned)), .protectedTerm)
        }
        // Another term's rule does not make a swap a revert.
        TestSupport.expectEqual(
            reason(learn("talk to Claude today", "talk to Gemini today", learned: ["claude"], rules: [("cloud", "Claude")])),
            .protectedTerm
        )
    }

    private static func testBounds() {
        let long = Array(repeating: "word", count: Learner.maxTokens + 1).joined(separator: " ")
        TestSupport.expectEqual(reason(learn(long, "word")), .tooLong)
        TestSupport.expectEqual(reason(learn("word", long)), .tooLong)
        TestSupport.expectEqual(reason(learn("", "something")), .empty)
        TestSupport.expectEqual(reason(learn("something", "  ")), .empty)
        // A replaced hunk over maxSideWords skips the partition search and is a rewrite at once.
        let started = Date()
        TestSupport.expectEqual(
            reason(learn(
                "rewrite one two three four five six seven eight now",
                "rewrite alpha bravo charlie delta echo foxtrot golf hotel now"
            )),
            .rewrite
        )
        TestSupport.expectEqual(
            reason(learn(
                "we ship versel kwen deep gram post gress sequel today",
                "we ship Vercel Qwen Deepgram Postgres SQL today"
            )),
            .rewrite
        )
        TestSupport.expect(Date().timeIntervalSince(started) < 1, "long hunks stay fast")
        // Sound-alike hunks that cannot be learned stop the edit once other changes exceed the
        // limit, instead of searching every remaining hunk.
        let manyHunksStarted = Date()
        let manyPasted = Array(repeating: "there four too eight and", count: 60).joined(separator: " ")
        let manyFinal = Array(repeating: "their for two ate and", count: 60).joined(separator: " ")
        TestSupport.expectEqual(reason(learn(manyPasted, manyFinal)), .rewording)
        TestSupport.expect(Date().timeIntervalSince(manyHunksStarted) < 1, "many unlearnable hunks stay fast")
    }

    /// Cleanup's edit of the raw text removes filler, so only each hunk is judged. Every other
    /// case in this file keeps the gates by default.
    /// A first name that is no ordinary word is a name at a sentence start too, which is where a
    /// search query's first words sit. An ordinary word's capital there still says nothing.
    private static func testSentenceStartNames() {
        func ungated(_ pasted: String, _ final: String) -> Learner.Outcome {
            Learner.learn(pasted: pasted, final: final, lexicon: lexicon, appliesEditGates: false)
        }
        // Mid-sentence and at a start now agree.
        TestSupport.expectEqual(fmt(ungated("pricing for cloud code", "pricing for Claude Code")), "cloud code->Claude Code:strong:later")
        TestSupport.expectEqual(fmt(ungated("cloud code pricing", "Claude Code pricing")), "cloud code->Claude Code:strong:later")
        TestSupport.expectEqual(fmt(learn("cloud code pricing", "Claude Code pricing")), "cloud code->Claude Code:strong:later")
        TestSupport.expectEqual(fmt(learn("it works. cloud code is good", "it works. Claude Code is good")), "cloud code->Claude Code:strong:later")
        TestSupport.expectEqual(fmt(learn("cloud is down", "Claude is down")), "cloud->Claude:strong:term")
        // A change of case alone at a start stays style.
        TestSupport.expectEqual(fmt(learn("claude is down", "Claude is down")), "nothing")
        // A first name that is also an ordinary word, and an ordinary word, teach nothing there.
        TestSupport.expectEqual(fmt(learn("pink is down", "Ping is down")), "nothing")
        TestSupport.expectEqual(fmt(learn("the mellow setup", "The yellow setup")), "nothing")
        TestSupport.expectEqual(fmt(learn("motion pricing", "Notion pricing")), "nothing")
        // Two first names are still a swap.
        TestSupport.expectEqual(fmt(learn("john is here", "Jason is here")), "nothing")
    }

    private static func testWithoutEditGates() {
        func ungated(_ pasted: String, _ final: String, manual: Set<String> = []) -> Learner.Outcome {
            Learner.learn(pasted: pasted, final: final, lexicon: lexicon, manualTerms: manual, appliesEditGates: false)
        }
        let raw = "um so ask cloud code to like refactor the uh parser"
        let cleaned = "Ask Claude Code to refactor the parser."
        TestSupport.expectEqual(fmt(learn(raw, cleaned)), "nothing")
        TestSupport.expectEqual(fmt(ungated(raw, cleaned)), "cloud code->Claude Code:strong:later")
        // No partial-rewrite downgrade: the strength stays as judged.
        TestSupport.expectEqual(
            fmt(ungated("so like basically versel was maybe sort of down", "Vercel was down.")),
            "versel->Vercel:strong:now"
        )
        // Hunk-level judging, the phrase cap and the candidate cap stay.
        TestSupport.expectEqual(fmt(ungated("the quick brown fox", "a slow red dog")), "nothing")
        TestSupport.expectEqual(fmt(ungated(raw, cleaned, manual: ["claude code"])), "nothing")
        TestSupport.expectEqual(fmt(ungated(cleaned, cleaned)), "nothing")
        TestSupport.expectEqual(
            fmt(ungated(String(repeating: "word ", count: Learner.maxTokens + 1), "word")),
            "nothing"
        )
        // The default still gates the same pair.
        TestSupport.expectEqual(reason(learn(raw, cleaned)), .rewrite)

        // Nothing gates a heavy rewrite here, so the hunks resolved are capped: a fix inside the
        // cap is found, and one past it is not looked at.
        func rewrite(hunks: Int) -> (pasted: String, final: String) {
            (
                Array(repeating: "there four too eight and", count: hunks).joined(separator: " ") + " versel now",
                Array(repeating: "their for two ate and", count: hunks).joined(separator: " ") + " Vercel now"
            )
        }
        let inside = rewrite(hunks: Learner.maxUngatedHunks - 1)
        TestSupport.expectEqual(fmt(ungated(inside.pasted, inside.final)), "versel->Vercel:strong:now")
        let past = rewrite(hunks: Learner.maxUngatedHunks)
        TestSupport.expectEqual(fmt(ungated(past.pasted, past.final)), "nothing")
        let longest = rewrite(hunks: Learner.maxTokens / 5 - 1)
        let started = Date()
        TestSupport.expectEqual(fmt(ungated(longest.pasted, longest.final)), "nothing")
        TestSupport.expect(Date().timeIntervalSince(started) < 5, "the longest rewrite stays fast")

        // Resolving stops at maxCandidates strong candidates, which is all that could be kept.
        let manyFixes = ungated(
            "use versel and kwen and postgress and supabayse and redis and deepgramm",
            "use Vercel and Qwen and Postgres and Supabase and Redis and Deepgram"
        )
        if case .learned(let candidates) = manyFixes {
            TestSupport.expectEqual(candidates.count, Learner.maxCandidates)
            TestSupport.expect(candidates.allSatisfy { $0.strength == .strong }, "Strong ones are kept")
        } else {
            TestSupport.expect(false, "The first fixes are learned")
        }
    }

    private static func testWordListParsing() {
        let parsed = LearningWordList.parse("# header line\n\nCloud\n  React  \n#another\nzed\n")
        TestSupport.expectEqual(parsed, ["cloud", "react", "zed"])
        // Fail closed below the minimum.
        TestSupport.expect(LearningWordList(knownWordsText: "cloud\nreact\n", firstNamesText: nil) == nil, "a short list fails closed")
        let manyWords = (0..<LearningWordList.minimumKnownWords).map { "word\($0)" }.joined(separator: "\n")
        guard let list = LearningWordList(knownWordsText: manyWords, firstNamesText: "Aaron\nJohn\n") else {
            TestSupport.expect(false, "a list at the minimum loads")
            return
        }
        TestSupport.expect(list.isKnown("word42"), "parsed words are known")
        TestSupport.expect(list.isKnown("the"), "everyday words are known too")
        TestSupport.expect(list.isEveryday("the") && !list.isEveryday("word42"), "the everyday tier is EverydayWords")
        TestSupport.expect(list.isFirstName("john") && !list.isFirstName("cloud"), "first names are lowercased")
        let noNames = LearningWordList(knownWordsText: manyWords, firstNamesText: nil)
        TestSupport.expect(noNames?.isFirstName("john") == false, "missing first names leave the filter empty")
        TestSupport.expect(LearningWordList.load(knownWordsURL: nil, firstNamesPath: "/nonexistent") == nil, "no resource, no list")
    }

    /// The real resource, read from the repository (make check runs at the repo root).
    private static func testBundledWordListResource() {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/LearningKnownWords.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            TestSupport.expect(false, "Resources/LearningKnownWords.txt is readable from the repository root")
            return
        }
        TestSupport.expect(text.hasPrefix("#"), "the resource starts with its header")
        TestSupport.expect(text.contains("Kevin Atkinson"), "the resource carries the SCOWL notice")
        TestSupport.expect(LearningWordList.parse(text).count > 80_000, "the resource holds the size-50 list")
        guard let list = LearningWordList.load(knownWordsURL: url, firstNamesPath: "/nonexistent/propernames") else {
            TestSupport.expect(false, "the resource loads")
            return
        }
        for word in ["cloud", "react", "zed", "lang", "json", "they're"] {
            TestSupport.expect(list.isKnown(word), "\(word) is a known word")
        }
        for word in ["versel", "kwen", "qwen", "claude", "deepgram"] {
            TestSupport.expect(!list.isKnown(word), "\(word) is not a known word")
        }
        TestSupport.expect(!list.isFirstName("john"), "an unreadable first-names file leaves the filter empty")
        // The production lexicon agrees with the synthetic one on cases that depend on it.
        TestSupport.expectEqual(fmt(learn("lang chain docs", "langchain docs", lexicon: list)), "lang chain->langchain:strong:later")
        TestSupport.expectEqual(fmt(learn("deploy it to versel tonight", "deploy it to Vercel tonight", lexicon: list)), "versel->Vercel:strong:now")
        TestSupport.expectEqual(fmt(learn("ask cloud to refactor the parser", "ask Claude to refactor the parser", lexicon: list)), "cloud->Claude:strong:term")
    }
}
