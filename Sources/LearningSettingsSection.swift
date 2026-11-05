import SwiftUI

/// The learning loop's Settings and Run Log views: learned chips under Custom Vocabulary,
/// learned rule rows under Corrections, the Learning card and the Run Log Fix editor. They
/// live outside SettingsView.swift like the Transforms section.

// MARK: - Learned terms (Custom Vocabulary card)

/// "Learned automatically (N)": one chip per learned term with a ✦ badge, a star and a delete.
/// Clicking a term edits it, which moves it to Custom Vocabulary. Hidden when nothing is learned.
struct LearnedVocabularyChips: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let items = appState.learnedVocabulary.rankedItems(category: nil, now: Date())
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Learned automatically (\(items.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(items) { item in
                        LearnedVocabularyChip(item: item)
                    }
                }
            }
        }
    }
}

private struct LearnedVocabularyChip: View {
    @EnvironmentObject var appState: AppState
    let item: LearnedVocabulary.Item
    @State private var isEditing = false
    @State private var editedText = ""

    var body: some View {
        HStack(spacing: 4) {
            Text("✦")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                editedText = item.text
                isEditing = true
            } label: {
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(item.state == .ambiguous ? Color.secondary : Color.primary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Term", text: $editedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Text(item.variants.contains(where: \.isRule)
                        ? "Editing makes it part of your Custom Vocabulary, and its learned corrections move to Corrections."
                        : "Editing makes it part of your Custom Vocabulary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 220, alignment: .leading)
                    HStack {
                        Spacer()
                        Button("Cancel") { isEditing = false }
                        Button("Move to Custom Vocabulary") {
                            appState.moveLearnedItemToVocabulary(item.id, as: editedText)
                            isEditing = false
                        }
                        .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
            }
            Button {
                appState.setLearnedItemStarred(item.id, !item.starred)
            } label: {
                Image(systemName: item.starred ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(item.starred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(item.starred ? "Starred: kept and sent first" : "Star to keep it and send it first")
            .accessibilityLabel(item.starred ? "Unstar" : "Star")
            Button {
                appState.removeLearnedItem(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete; it will not be learned again")
            .accessibilityLabel("Delete learned term")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule().stroke(Color.secondary.opacity(item.state == .ambiguous ? 0.15 : 0.3), lineWidth: 1)
        )
        .help(LearnedVocabulary.tooltip(for: item, now: Date()))
    }
}

// MARK: - Learned rules (Corrections card)

/// Read-only "✦ heard → term" rows. Editing converts a row to a manual correction; deleting
/// stops the rule and keeps it from being learned again. A rule FreeFlow does not apply (its
/// term is not sure, or a manual entry keeps the word) is dimmed and says why.
struct LearnedRuleRows: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ForEach(EffectiveVocabulary.listedRules(
            manualVocabulary: appState.customVocabulary,
            manualCorrections: appState.dictionaryCorrections,
            learned: appState.learnedVocabulary
        )) { listed in
            let row = listed.rule
            HStack(spacing: 8) {
                Text("✦ \(row.variant.heard) → \(row.item.text)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .opacity(listed.unused == nil ? 1 : 0.55)
                    .help(listed.unused?.helpText ?? "Learned")
                if let unused = listed.unused {
                    Text("Not in use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(unused.helpText)
                }
                Spacer()
                Button {
                    appState.moveLearnedRuleToCorrections(itemID: row.item.id, variantID: row.variant.id)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit as manual correction")
                .accessibilityLabel("Edit as manual correction")
                Button {
                    appState.removeLearnedRule(itemID: row.item.id, variantID: row.variant.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Remove learned correction")
                .accessibilityLabel("Remove learned correction")
            }
        }
    }
}

// MARK: - Learning card

struct LearningSettingsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var confirmsDeleteAll = false

    /// Deleting learned data neither turns learning off nor disconnects Claude Code.
    private var learningContinuesText: String {
        guard appState.learningEnabled else { return "Learning stays off." }
        return appState.claudeCodeHookConnected
            ? "Claude Code stays connected and learning continues; use Disconnect or turn off Learn automatically to stop it."
            : "Learning continues; turn off Learn automatically to stop it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Learn automatically", isOn: $appState.learningEnabled)

            Text("FreeFlow learns misheard words and names from Fix in the Run Log, from what you send in Claude Code once it is connected, from your Google searches in Chrome, and from cleanup fixes you keep. Learned items stay on this Mac and go only where your vocabulary already goes: your streaming provider's key terms and cleanup spellings. Turning this off stops learning; learned items stay in use until you delete them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ClaudeCodeConnectionRow()

            HStack {
                Button("Undo last learned") {
                    appState.undoLastLearned()
                }
                .disabled(appState.lastLearnedChange == nil)

                Button("Delete all learned data…", role: .destructive) {
                    confirmsDeleteAll = true
                }
            }

            Text(appState.learnedVocabulary.activityLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.learnedStoreKeptUnread {
                Text("Learned data saved by another FreeFlow version is kept as it is. This version uses what it can read of it but does not save over it, so changes here, including learning, deleting or editing a learned term or correction, last only until you quit. Delete all learned data removes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Delete all learned data?", isPresented: $confirmsDeleteAll) {
            Button("Delete", role: .destructive) {
                appState.deleteAllLearnedData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Learned terms and corrections, what FreeFlow is not sure about yet, and the list of removed items are deleted. Your Custom Vocabulary and Corrections stay as they are. Run Log entries keep the cleanup prompts they were sent with, which can name learned terms, until you delete those entries. \(learningContinuesText)")
        }
    }
}

// MARK: - Claude Code connection

/// Connect and Disconnect for the Claude Code hook. The settings file is read only once the
/// user has connected, and changed only by these two buttons.
private struct ClaudeCodeConnectionRow: View {
    @EnvironmentObject var appState: AppState
    @State private var showsConsent = false

    private var statusText: String {
        guard appState.claudeCodeHookConnected else { return "Not connected" }
        return appState.learningEnabled ? "Connected" : "Connected, but learning is off"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code")
                        .font(.callout)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.claudeCodeHookConnected {
                    Button("Disconnect") {
                        appState.disconnectClaudeCode()
                    }
                } else {
                    Button("Connect Claude Code…") {
                        showsConsent = true
                    }
                    .disabled(!appState.learningEnabled)
                    .help(appState.learningEnabled ? "Shows the change before making it" : "Turn on Learn automatically to connect")
                }
            }
            if appState.claudeHookNotReporting {
                Text(ClaudeHookHealth.warningText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let message = appState.claudeHookStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            appState.refreshClaudeCodeHookStatus()
        }
        .sheet(isPresented: $showsConsent) {
            ClaudeCodeConsentSheet(isPresented: $showsConsent)
                .environmentObject(appState)
        }
    }
}

/// Shows the exact entry and the file it changes. Nothing is written until Connect.
private struct ClaudeCodeConsentSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var failureText: String?
    @State private var offersSnippet = false

    private var snippet: String { AppState.claudeCodeHookSnippet }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Claude Code")
                .font(.headline)
            Text("FreeFlow will add this entry to \(AppState.claudeCodeSettingsDisplayPath):")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 170)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code will send each prompt from its VS Code panel to FreeFlow on this Mac, including what it attaches to the prompt, such as your editor selection or open file, and details such as the working folder and session paths. FreeFlow discards those attachments and details at once.")
                Text("Prompts stay in memory and are used only when they match a recent FreeFlow paste. They are never stored or logged.")
                Text("Connect and Disconnect each save a backup beside the file first, with everything the file holds, and FreeFlow does not delete those backups. Key order and spacing in the file may change.")
                Text("Disconnect removes only this entry.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let failureText {
                Text(failureText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if offersSnippet {
                    Button("Copy snippet") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                    }
                }
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                Button("Connect") {
                    connect()
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func connect() {
        switch appState.connectClaudeCode() {
        case .done, .alreadyDone:
            isPresented = false
        case .invalidJSON, .unexpectedShape:
            failureText = "FreeFlow did not change the file: it is not the settings JSON FreeFlow expected. FreeFlow can only listen once it can read the file, so the snippet alone is not enough. Make the file valid JSON, add the entry with the snippet if you like, then press Connect again."
            offersSnippet = true
        case .ioFailure:
            failureText = "FreeFlow could not write the file, so it stays as it was. You can add the entry yourself with the snippet, then press Connect again so FreeFlow starts listening."
            offersSnippet = true
        }
    }
}

// MARK: - Run Log Fix

/// The Run Log row's Fix editor, prefilled with what FreeFlow pasted. The typed text lives in
/// this view only; just the words and names learned from it are kept, never the sentence.
struct RunLogFixView: View {
    @EnvironmentObject var appState: AppState
    let item: PipelineHistoryItem
    let onClose: () -> Void

    @State private var correctedText = ""
    @State private var isLearning = false
    @State private var resultText: String?
    /// The text last learned from: the same fix is not submitted twice.
    @State private var submittedText: String?
    /// What the last fix learned, so its result line follows a later Undo or delete.
    @State private var learnedChange: LearnedVocabulary.Change?

    private var pastedText: String { RunLogFix.pastedText(for: item) ?? "" }

    /// Everything the last fix learned was undone, deleted or edited since.
    private var learnedIsGone: Bool {
        learnedChange.map { !RunLogFix.isStillLearned($0, in: appState.learnedVocabulary) } ?? false
    }

    private var canLearn: Bool {
        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.learningEnabled && !isLearning && !trimmed.isEmpty && trimmed != pastedText
            && trimmed != submittedText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fix what FreeFlow pasted")
                .font(.subheadline.weight(.semibold))
            Text("Correct the text below. Only misheard words and names are learned, never the sentence.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $correctedText)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            HStack(spacing: 8) {
                Button("Learn from this fix") {
                    learn()
                }
                .disabled(!canLearn)
                Button("Cancel") {
                    onClose()
                }
                if isLearning {
                    ProgressView()
                        .controlSize(.small)
                }
                if let resultText {
                    Text(resultText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            correctedText = pastedText
        }
        .onChange(of: learnedIsGone) { gone in
            guard gone else { return }
            learnedChange = nil
            resultText = RunLogFix.noLongerLearnedText
            submittedText = nil
        }
    }

    private func learn() {
        let text = correctedText
        submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isLearning = true
        resultText = nil
        learnedChange = nil
        Task {
            let result = await appState.learnFromRunLogFix(item: item, correctedText: text)
            isLearning = false
            resultText = result.text
            learnedChange = result.learned
        }
    }
}
