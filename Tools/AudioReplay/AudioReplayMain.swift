import Foundation

/// build/audio-replay: replays your own recordings through Deepgram under named
/// variants and scores them (Tools/AudioReplay/README.md). Output carries only
/// numbers, variant names, statuses and paths you typed: never transcript text,
/// the listen URL or the key.
@main
struct AudioReplayMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let code: Int32
        switch arguments.first {
        case nil, "--help", "-h", "help":
            say(usage)
            code = arguments.isEmpty ? 1 : 0
        case "stats":
            code = stats(Array(arguments.dropFirst()))
        case "run":
            code = await run(Array(arguments.dropFirst()))
        default:
            complain("Unknown command. Run audio-replay --help for usage.")
            code = 1
        }
        exit(code)
    }

    private static let usage = """
        audio-replay: A/B audio and Deepgram settings on your own recordings (developer tool).

        Usage:
          audio-replay stats <audio file>...
              Offline level and spectrum numbers. Needs no key and sends nothing.

          audio-replay run --manifest <tsv> --variants <preset|file> --out <dir> [options]
              Streams every manifest item to Deepgram once per variant and repeat,
              after printing the estimated cost and asking you to confirm.
              --repeat N              runs per item and variant, 1-10 (default 1)
              --concurrency N         streams in flight, 1-4 (default 2)
              --key-file <path>       read the key from a file outside any git repository
                                      (default: the DEEPGRAM_API_KEY environment variable)
              --price-per-minute USD  price used for the estimate (default 0.0077)
              --save-transcripts      also write each hypothesis to <out>/transcripts (0600 files)
              --yes                   confirm the cost without a prompt

        Presets: \(ReplayEvalCore.presetNames.joined(separator: ", "))
        Manifest lines: <audio path><TAB><reference text path>[<TAB><keyterms file>]
        Details: Tools/AudioReplay/README.md
        """

    // MARK: Output

    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func complain(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let padding = String(repeating: " ", count: max(0, width - text.count))
        return left ? padding + text : text + padding
    }

    private static func number(_ value: Double?, _ format: String) -> String {
        value.map { String(format: format, $0) } ?? "-"
    }

    // MARK: stats

    private static func stats(_ paths: [String]) -> Int32 {
        guard !paths.isEmpty else {
            complain("stats needs at least one audio file.")
            return 1
        }
        var failures = 0
        for (index, path) in paths.enumerated() {
            let url = absoluteURL(path)
            say("[\(index + 1)] \(url.lastPathComponent)")
            let source: ReplayAudioPipeline.SourceAudio
            do {
                source = try ReplayAudioPipeline.load(url)
            } catch {
                complain("[\(index + 1)] error: \(description(of: error))")
                failures += 1
                continue
            }
            let level = ReplayEvalCore.levelStats(source.samples, sampleRate: source.sampleRate)
            let channels = source.channelCount == 1 ? "mono" : "\(source.channelCount) channels (channel 1 analysed)"
            say("    format: \(rateText(source.sampleRate)), \(channels), \(source.formatName), \(String(format: "%.2f", source.duration)) s")
            say("    peak: \(String(format: "%.1f", level.peakDBFS)) dBFS")
            if let rms = level.activeRMSDBFS {
                say("    speech RMS: \(String(format: "%.1f", rms)) dBFS (active \(String(format: "%.0f", level.activeFraction * 100))% of the file)")
            } else {
                say("    speech RMS: - (nothing above \(Int(ReplayEvalCore.activityThresholdDBFS)) dBFS)")
            }
            say("    energy above 4 / 7 / 8 kHz: "
                + [level.energyAbove4kHz, level.energyAbove7kHz, level.energyAbove8kHz]
                .map { String(format: "%.2f%%", $0 * 100) }
                .joined(separator: " / "))
        }
        return failures == 0 ? 0 : 1
    }

    private static func rateText(_ sampleRate: Double) -> String {
        sampleRate == sampleRate.rounded() ? "\(Int(sampleRate)) Hz" : String(format: "%.1f Hz", sampleRate)
    }

    private static func description(of error: Error) -> String {
        if let error = error as? ReplayAudioPipeline.PipelineError { return error.description }
        if let error = error as? ReplayEvalCore.ParseError { return error.description }
        return "unexpected error"
    }

    // MARK: run

    private struct UsageError: Error {
        let message: String
    }

    private struct RunOptions {
        var manifest = ""
        var variants = ""
        var out = ""
        var repeats = 1
        var concurrency = 2
        var keyFile: String?
        var pricePerMinute = ReplayEvalCore.defaultPricePerMinuteUSD
        var saveTranscripts = false
        var yes = false
    }

    private static func parseRunOptions(_ arguments: [String]) throws -> RunOptions {
        var options = RunOptions()
        var index = 0
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw UsageError(message: "\(flag) needs a value.") }
            return arguments[index]
        }
        func integer(for flag: String, in range: ClosedRange<Int>) throws -> Int {
            guard let parsed = Int(try value(for: flag)), range.contains(parsed) else {
                throw UsageError(message: "\(flag) must be \(range.lowerBound)-\(range.upperBound).")
            }
            return parsed
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--manifest": options.manifest = try value(for: flag)
            case "--variants": options.variants = try value(for: flag)
            case "--out": options.out = try value(for: flag)
            case "--repeat": options.repeats = try integer(for: flag, in: 1...10)
            case "--concurrency": options.concurrency = try integer(for: flag, in: 1...4)
            case "--key-file": options.keyFile = try value(for: flag)
            case "--price-per-minute":
                guard let price = Double(try value(for: flag)), price.isFinite, (0...100).contains(price) else {
                    throw UsageError(message: "--price-per-minute must be a number of US dollars, 0-100.")
                }
                options.pricePerMinute = price
            case "--save-transcripts": options.saveTranscripts = true
            case "--yes": options.yes = true
            default: throw UsageError(message: "Unknown option \(flag). Run audio-replay --help for usage.")
            }
            index += 1
        }
        for (flag, given) in [("--manifest", options.manifest), ("--variants", options.variants), ("--out", options.out)]
        where given.isEmpty {
            throw UsageError(message: "run needs \(flag). Run audio-replay --help for usage.")
        }
        return options
    }

    private struct PreparedItem {
        var entry: ReplayEvalCore.ManifestEntry
        var reference: String
        var keyterms: [String]
        var audioSeconds: Double
        /// Little-endian PCM16 per variant audioKey.
        var pcm: [String: Data]
    }

    private struct Job {
        var itemIndex: Int
        var variantIndex: Int
        var repeatIndex: Int
    }

    private struct JobResult {
        var job: Job
        var outcome: ReplayStreamOutcome
    }

    private static func run(_ arguments: [String]) async -> Int32 {
        let options: RunOptions
        do {
            options = try parseRunOptions(arguments)
        } catch {
            complain((error as? UsageError)?.message ?? "Invalid arguments.")
            return 1
        }

        // 1. Variants: a preset name, or a file.
        let variantsText: String
        if !options.variants.contains("/"), let preset = ReplayEvalCore.preset(named: options.variants) {
            variantsText = preset
        } else if let text = try? String(contentsOf: absoluteURL(options.variants), encoding: .utf8) {
            variantsText = text
        } else {
            complain("--variants is neither a preset (\(ReplayEvalCore.presetNames.joined(separator: ", "))) nor a readable UTF-8 file.")
            return 1
        }
        let variants: [ReplayEvalCore.Variant]
        do {
            variants = try ReplayEvalCore.parseVariants(variantsText)
        } catch {
            complain("Variants: \(description(of: error))")
            return 1
        }

        // 2. Manifest, references and keyterms.
        let manifestURL = absoluteURL(options.manifest)
        guard let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            complain("Could not read --manifest as UTF-8 text.")
            return 1
        }
        let entries: [ReplayEvalCore.ManifestEntry]
        do {
            entries = try ReplayEvalCore.parseManifest(manifestText, baseDirectory: manifestURL.deletingLastPathComponent())
        } catch {
            complain("Manifest: \(description(of: error))")
            return 1
        }
        var items: [PreparedItem] = []
        for entry in entries {
            let label = "Manifest item \(entry.item) (line \(entry.line))"
            guard let reference = try? String(contentsOf: entry.reference, encoding: .utf8) else {
                complain("\(label): could not read the reference file as UTF-8 text.")
                return 1
            }
            guard !ReplayEvalCore.normalizedWords(reference).isEmpty else {
                complain("\(label): the reference text is empty.")
                return 1
            }
            var keyterms: [String] = []
            if let keytermsURL = entry.keyterms {
                guard let text = try? String(contentsOf: keytermsURL, encoding: .utf8) else {
                    complain("\(label): could not read the keyterms file as UTF-8 text.")
                    return 1
                }
                keyterms = ReplayEvalCore.keytermList(fromText: text)
            }
            items.append(PreparedItem(entry: entry, reference: reference, keyterms: keyterms, audioSeconds: 0, pcm: [:]))
        }

        // 3. Key: --key-file wins over DEEPGRAM_API_KEY.
        let key: ReplayEvalCore.Secret
        if let keyFile = options.keyFile {
            let keyURL = absoluteURL(keyFile)
            guard !isInsideGitWorkTree(keyURL) else {
                complain("Refusing --key-file inside a git work tree. Keep the key file outside every repository.")
                return 1
            }
            guard let text = try? String(contentsOf: keyURL, encoding: .utf8) else {
                complain("Could not read --key-file as UTF-8 text.")
                return 1
            }
            // The message never shows the file: it may hold other credentials.
            guard let secret = ReplayEvalCore.Secret(text) else {
                complain("The key file must hold only the key: \(ReplayEvalCore.Secret.requirement). Nothing was sent.")
                return 1
            }
            key = secret
        } else if let raw = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"],
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let secret = ReplayEvalCore.Secret(raw) else {
                complain("DEEPGRAM_API_KEY must hold only the key: \(ReplayEvalCore.Secret.requirement). Nothing was sent.")
                return 1
            }
            key = secret
        } else {
            complain("""
                No Deepgram key. Set one without it landing in your shell history:
                  read -s DEEPGRAM_API_KEY; export DEEPGRAM_API_KEY
                or pass --key-file <path> (chmod 600, outside any git repository).
                """)
            return 1
        }
        // Variant names are printed and written to disk, and a key file parses as a variant.
        guard !ReplayEvalCore.variantNamesExposeKey(variants.map(\.name), key: key) else {
            complain("Refusing to run: a variant name contains the Deepgram key. Check that --variants is not the key file. Nothing was sent.")
            return 1
        }

        // 4. Output folder: outside any git work tree, never overwriting results.
        let outURL = absoluteURL(options.out)
        guard !isInsideGitWorkTree(outURL) else {
            complain("Refusing --out \(options.out): it is inside a git work tree. Use a folder outside every repository, such as ~/FreeFlowAudioLab/results.")
            return 1
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            complain("--out \(options.out) exists and is not a folder.")
            return 1
        }
        let resultsPath = outURL.appendingPathComponent("results.csv").path
        guard !FileManager.default.fileExists(atPath: resultsPath) else {
            complain("--out \(options.out) already has a results.csv. Choose a new folder; results are never overwritten.")
            return 1
        }

        // 5. Decode and render every item × audio configuration before anything is sent.
        let audioKeys = variants.reduce(into: [String: ReplayEvalCore.Variant]()) { keys, variant in
            if keys[variant.audioKey] == nil { keys[variant.audioKey] = variant }
        }
        say("Preparing audio: \(items.count) item(s) × \(audioKeys.count) audio configuration(s)...")
        for index in items.indices {
            let entry = items[index].entry
            do {
                let source = try ReplayAudioPipeline.load(entry.audio)
                items[index].audioSeconds = source.duration
                for (audioKey, variant) in audioKeys {
                    do {
                        let samples = try ReplayAudioPipeline.render(source, for: variant)
                        items[index].pcm[audioKey] = ReplayEvalCore.littleEndianData(samples)
                    } catch {
                        complain("Manifest item \(entry.item) (line \(entry.line)), variant \(variant.name): \(description(of: error)). Nothing was sent.")
                        return 1
                    }
                }
            } catch {
                complain("Manifest item \(entry.item) (line \(entry.line)): \(description(of: error)). Nothing was sent.")
                return 1
            }
        }

        // 6. Plan. When a prompt follows and stdout is redirected, the plan and the
        // prompt go to stderr, so they reach the person who has to answer.
        let planToStandardError = !options.yes && isatty(STDOUT_FILENO) != 1
        let planHandle = planToStandardError ? FileHandle.standardError : FileHandle.standardOutput
        func show(_ text: String) { planHandle.write(Data((text + "\n").utf8)) }
        let totalSeconds = items.reduce(0) { $0 + $1.audioSeconds }
        let sentSeconds = totalSeconds * Double(variants.count * options.repeats)
        let cost = ReplayEvalCore.estimatedCostUSD(
            audioSeconds: totalSeconds,
            variants: variants.count,
            repeats: options.repeats,
            pricePerMinute: options.pricePerMinute
        )
        let jobCount = items.count * variants.count * options.repeats
        // Streaming time at each variant's pace, plus about a second per stream for the handshake and finalize.
        let pacedSeconds = variants.reduce(0) { $0 + totalSeconds * $1.pacing.wallTimeFactor } * Double(options.repeats)
        let wallSeconds = (pacedSeconds + Double(jobCount)) / Double(options.concurrency)
        let priceSource = options.pricePerMinute == ReplayEvalCore.defaultPricePerMinuteUSD
            ? "Nova-3 streaming list price; set --price-per-minute for your plan"
            : "from --price-per-minute"
        show("")
        show("Plan")
        show("  Items: \(items.count), \(String(format: "%.1f", totalSeconds)) s of audio")
        show("  Audio sent: \(String(format: "%.1f", totalSeconds)) s × \(variants.count) variant(s) × \(options.repeats) repeat(s) = \(String(format: "%.1f", sentSeconds)) s (\(String(format: "%.2f", sentSeconds / 60)) min) in \(jobCount) stream(s)")
        show("  Estimated cost: $\(String(format: "%.4f", cost)) at $\(String(format: "%.4f", options.pricePerMinute))/min (\(priceSource))")
        show("  Estimated wall time: about \(String(format: "%.1f", wallSeconds / 60)) min at concurrency \(options.concurrency)")
        show("  Variants: \(variants.map(\.name).joined(separator: ", ")) (paired baseline: \(variants[0].name))")
        show("  Output: \(options.out)")
        show(options.saveTranscripts
            ? "  Transcripts: saved as 0600 files in \(options.out)/transcripts"
            : "  Transcripts: not saved (results.csv holds numbers only)")
        if variants.contains(where: { $0.keyterms != .none }), items.allSatisfy({ $0.keyterms.isEmpty }) {
            show("  Note: some variants send keyterms, but no manifest line has a keyterms column, so none will be sent.")
        }

        // 7. Confirm.
        if !options.yes {
            guard isatty(STDIN_FILENO) == 1 else {
                complain("Standard input is not a terminal: pass --yes to confirm the cost. Nothing was sent.")
                return 1
            }
            planHandle.write(Data("Send this audio to Deepgram? Type y to continue: ".utf8))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                show("Cancelled. Nothing was sent.")
                return 1
            }
        }

        // 8. Output files.
        let transcriptsURL = outURL.appendingPathComponent("transcripts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if options.saveTranscripts {
                try FileManager.default.createDirectory(
                    at: transcriptsURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            complain("Could not create the --out folder. Nothing was sent.")
            return 1
        }
        guard let results = ExclusiveFile(path: resultsPath), results.write(ReplayEvalCore.csvHeader + "\n") else {
            complain("Could not create results.csv in --out. Nothing was sent.")
            return 1
        }

        // 9-10. Jobs: repeat -> item -> variant, variants rotated per item.
        var jobs: [Job] = []
        for repeatIndex in 1...options.repeats {
            for itemIndex in items.indices {
                for offset in variants.indices {
                    jobs.append(Job(itemIndex: itemIndex, variantIndex: (offset + itemIndex) % variants.count, repeatIndex: repeatIndex))
                }
            }
        }
        var runs: [ReplayEvalCore.RunMetrics] = []
        var completed = 0
        var started = 0
        var writeFailed = false
        await withTaskGroup(of: JobResult.self) { group in
            func startNext() {
                let job = jobs[started]
                started += 1
                let item = items[job.itemIndex]
                let variant = variants[job.variantIndex]
                let frames = ReplayEvalCore.frames(
                    of: item.pcm[variant.audioKey] ?? Data(),
                    sampleRate: variant.sampleRate,
                    frameMilliseconds: variant.frameMilliseconds
                )
                let sent = variant.keyterms.select(from: item.keyterms)
                group.addTask {
                    JobResult(
                        job: job,
                        outcome: await ReplayDeepgramClient.stream(frames: frames, variant: variant, keyterms: sent, key: key)
                    )
                }
            }
            var stopScheduling = false
            while started < min(options.concurrency, jobs.count) { startNext() }
            while let result = await group.next() {
                completed += 1
                let item = items[result.job.itemIndex]
                let variant = variants[result.job.variantIndex]
                let outcome = result.outcome
                let metrics = ReplayEvalCore.makeMetrics(
                    variant: variant.name,
                    item: item.entry.item,
                    repeatIndex: result.job.repeatIndex,
                    status: outcome.status,
                    audioSeconds: item.audioSeconds,
                    reference: item.reference,
                    hypothesis: outcome.finalTranscript,
                    keyterms: item.keyterms,
                    finals: outcome.finals,
                    resultCount: outcome.resultCount,
                    unfinalizedAtEnd: outcome.unfinalizedAtEnd,
                    millisecondsToFromFinalize: outcome.millisecondsToFromFinalize,
                    millisecondsToMetadata: outcome.millisecondsToMetadata
                )
                runs.append(metrics)
                if !results.write(ReplayEvalCore.csvRow(metrics) + "\n"), !writeFailed {
                    writeFailed = true
                    complain("Could not append to results.csv; the summary below still covers every run.")
                }
                if options.saveTranscripts, outcome.status == .ok {
                    let name = "item\(String(format: "%03ld", item.entry.item))-\(variant.name)-r\(result.job.repeatIndex).txt"
                    let path = transcriptsURL.appendingPathComponent(name).path
                    if !(ExclusiveFile(path: path)?.write(outcome.finalTranscript + "\n") ?? false) {
                        complain("Could not write the transcript for item \(item.entry.item), \(variant.name), repeat \(result.job.repeatIndex).")
                    }
                }
                say("[\(completed)/\(jobs.count)] \(variant.name) item \(item.entry.item) repeat \(result.job.repeatIndex): \(outcome.status.csvValue)")
                if outcome.status.isAuthenticationFailure, !stopScheduling {
                    stopScheduling = true
                    complain("Deepgram refused the key (HTTP 401/403). No new streams will start. Check the key and that its project can use live transcription.")
                }
                if !stopScheduling, started < jobs.count { startNext() }
            }
        }

        // 11. Summary.
        printSummary(variants: variants, runs: runs)
        if started < jobs.count {
            say("\(jobs.count - started) stream(s) were not started.")
        }
        say("Results: \(options.out)/results.csv")
        let allOK = started == jobs.count && runs.allSatisfy { $0.status == .ok }
        return allOK && !writeFailed ? 0 : 1
    }

    private static func printSummary(variants: [ReplayEvalCore.Variant], runs: [ReplayEvalCore.RunMetrics]) {
        let nameWidth = max(7, variants.map(\.name.count).max() ?? 0) + 2
        let columns: [(title: String, width: Int)] = [
            ("Files", 6), ("WER %", 7), ("S/D/I", 12), ("1st/last del", 13), ("KT recall", 10), ("KT false", 9),
            ("Overlaps", 9), ("from_finalize p50/p95 ms", 25), ("Metadata p50/p95 ms", 20), ("Unfinal", 8), ("Failed", 7),
        ]
        say("")
        say(pad("Variant", nameWidth) + columns.map { pad($0.title, $0.width) }.joined())
        for variant in variants {
            let summary = ReplayEvalCore.summarize(runs.filter { $0.variant == variant.name })
            let cells = [
                "\(summary.files)",
                number(summary.wordErrorRate.map { $0 * 100 }, "%.2f"),
                "\(summary.substitutions)/\(summary.deletions)/\(summary.insertions)",
                "\(summary.firstWordDeletions)/\(summary.lastWordDeletions)",
                "\(summary.keytermsRecalled)/\(summary.keytermsExpected)",
                "\(summary.keytermFalseInsertions)",
                "\(summary.overlaps)",
                "\(number(summary.fromFinalizeP50, "%.0f"))/\(number(summary.fromFinalizeP95, "%.0f"))",
                "\(number(summary.metadataP50, "%.0f"))/\(number(summary.metadataP95, "%.0f"))",
                "\(summary.unfinalized)",
                "\(summary.failed)",
            ]
            say(pad(variant.name, nameWidth) + zip(cells, columns).map { pad($0, $1.width) }.joined())
        }

        guard variants.count > 1 else { return }
        let baseline = variants[0]
        let baselineWER = ReplayEvalCore.perItemMeanWER(runs.filter { $0.variant == baseline.name })
        say("")
        say("Paired vs \(baseline.name) (per-file WER averaged over repeats; a negative ΔWER means fewer errors)")
        say(pad("Variant", nameWidth) + pad("Files", 7) + pad("Mean ΔWER pts", 15) + pad("Better/Worse/Same", 19) + "Sign-test p")
        for variant in variants.dropFirst() {
            let comparison = ReplayEvalCore.pairedComparison(
                baseline: baselineWER,
                candidate: ReplayEvalCore.perItemMeanWER(runs.filter { $0.variant == variant.name })
            )
            say(pad(variant.name, nameWidth)
                + pad("\(comparison.files)", 7)
                + pad(comparison.files > 0 ? String(format: "%+.2f", comparison.meanDelta * 100) : "-", 15)
                + pad("\(comparison.wins)/\(comparison.losses)/\(comparison.ties)", 19)
                + String(format: "%.3f", comparison.pValue))
        }
        say("With fewer than 6 better+worse files no difference can reach p < 0.05; compare deltas with the determinism spread.")
    }

    // MARK: Paths

    /// Expands ~, resolves against the current folder and removes . and .. components.
    private static func absoluteURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).absoluteURL.standardized
    }

    /// Checks both the path as given and the path with symlinks resolved on its
    /// deepest existing ancestor.
    private static func isInsideGitWorkTree(_ url: URL) -> Bool {
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        return ReplayEvalCore.gitWorkTreeRoot(containing: url, exists: exists) != nil
            || ReplayEvalCore.gitWorkTreeRoot(containing: resolvingExistingAncestor(url), exists: exists) != nil
    }

    private static func resolvingExistingAncestor(_ url: URL) -> URL {
        var existing = url.path
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            remainder.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = existing
        if let real = realpath(existing, nil) {
            resolved = String(cString: real)
            free(real)
        }
        for component in remainder {
            resolved = (resolved as NSString).appendingPathComponent(component)
        }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }
}

/// A file created with O_CREAT|O_EXCL|O_NOFOLLOW at mode 0600: never overwrites
/// and never follows a symlink. Each write goes straight to the descriptor.
private final class ExclusiveFile {
    private let handle: FileHandle

    init?(path: String) {
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func write(_ text: String) -> Bool {
        do {
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }
}
