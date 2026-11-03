import SwiftUI

/// Content of the Transforms settings card: the built-in shortcut rows, Auto Apply After Dictation
/// and the custom prompts list. Lives outside SettingsView.swift like the other shortcut views.
struct TransformsSettingsSection: View {
    @EnvironmentObject var appState: AppState

    @State private var activeCaptureRole: ShortcutRole?
    @State private var polishValidationMessage: String?
    @State private var promptEngineerValidationMessage: String?
    @State private var showingEditor = false
    @State private var editingTransform: CustomTransform?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(TransformCore.settingsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            ShortcutRoleSection(
                role: .polishTransform,
                selection: appState.polishTransformShortcut,
                validationMessage: polishValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .polishTransform },
                    set: { activeCaptureRole = $0 ? .polishTransform : nil }
                ),
                onSelect: { binding in
                    polishValidationMessage = appState.setShortcut(binding, for: .polishTransform)
                }
            )

            ShortcutRoleSection(
                role: .promptEngineerTransform,
                selection: appState.promptEngineerTransformShortcut,
                validationMessage: promptEngineerValidationMessage,
                isCapturing: Binding(
                    get: { activeCaptureRole == .promptEngineerTransform },
                    set: { activeCaptureRole = $0 ? .promptEngineerTransform : nil }
                ),
                onSelect: { binding in
                    promptEngineerValidationMessage = appState.setShortcut(binding, for: .promptEngineerTransform)
                }
            )

            Divider()

            autoApplySection

            Divider()

            customPromptsSection
        }
        .onChange(of: activeCaptureRole) { role in
            if role == nil {
                appState.resumeHotkeyMonitoringAfterShortcutCapture()
            } else {
                appState.suspendHotkeyMonitoringForShortcutCapture()
            }
        }
        .onDisappear {
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
        }
        .sheet(isPresented: $showingEditor, onDismiss: { editingTransform = nil }) {
            CustomTransformEditorView(isPresented: $showingEditor, transform: $editingTransform)
        }
    }

    private var autoApplySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Auto Apply After Dictation", selection: $appState.transformAutoApply) {
                Text("Off").tag(TransformAutoApplyPreference.off)
                Text("Polish").tag(TransformAutoApplyPreference.polish)
                Text("Prompt Engineer").tag(TransformAutoApplyPreference.promptEngineer)
                ForEach(appState.customTransforms) { transform in
                    Text(transform.name).tag(TransformAutoApplyPreference.custom(transform.id))
                }
            }
            .pickerStyle(.menu)

            Toggle("Only in AI apps", isOn: $appState.transformAutoApplyAIAppsOnly)
                .disabled(appState.transformAutoApply == .off)

            Text("Runs the chosen transform on every dictation after cleanup and before pasting. With \"Only in AI apps\" on it applies in ChatGPT, Claude and similar chats, where Prompt Engineer belongs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var customPromptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Custom prompts (\(appState.customTransforms.count) of \(CustomTransform.maxCount))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Add Prompt") {
                    editingTransform = nil
                    showingEditor = true
                }
                .disabled(appState.customTransforms.count >= CustomTransform.maxCount)
            }

            Text("Up to eight prompts, each with a name, a unique shortcut, instructions of at most 50 words and up to five samples of 50–500 words.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !appState.customTransforms.isEmpty {
                VStack(spacing: 1) {
                    ForEach(appState.customTransforms) { transform in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(transform.name)
                                    .font(.headline)
                                Spacer()
                                Button("Edit") {
                                    editingTransform = transform
                                    showingEditor = true
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)

                                Button("Delete") {
                                    appState.removeCustomTransform(id: transform.id)
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            Text(transform.shortcut?.displayName ?? "No shortcut")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(transform.instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("\(transform.samples.count) samples")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                    }
                }
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }
}

/// Edits a custom prompt draft; nothing is persisted until Save, which re-validates through AppState.
struct CustomTransformEditorView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @Binding var transform: CustomTransform?

    @State private var draft = CustomTransform(name: "", instructions: "")
    @State private var isCapturingShortcut = false
    @State private var shortcutValidationMessage: String?
    @State private var saveMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text(transform == nil ? "Add Prompt" : "Edit Prompt")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                    TextField("e.g. Friendly reply", text: $draft.name)
                        .textFieldStyle(.roundedBorder)

                    Text("Instructions")
                        .font(.caption.weight(.semibold))
                        .padding(.top, 8)
                    TextEditor(text: $draft.instructions)
                        .font(.body)
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    Text("\(instructionWordCount)/\(CustomTransform.maxInstructionWords) words")
                        .font(.caption)
                        .foregroundStyle(instructionWordCount > CustomTransform.maxInstructionWords ? Color.red : Color.secondary)

                    HStack {
                        Text("Samples")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Add Sample") {
                            draft.samples.append("")
                        }
                        .disabled(draft.samples.count >= CustomTransform.maxSamples)
                    }
                    .padding(.top, 8)

                    ForEach(draft.samples.indices, id: \.self) { index in
                        sampleEditor(at: index)
                    }

                    ShortcutRoleSection(
                        role: .customTransform(draft.id),
                        selection: draft.shortcut ?? .disabled,
                        validationMessage: shortcutValidationMessage,
                        isCapturing: $isCapturingShortcut,
                        onSelect: { binding in
                            shortcutValidationMessage = appState.shortcutValidationMessage(binding, for: .customTransform(draft.id))
                            if shortcutValidationMessage == nil {
                                draft.shortcut = binding.isDisabled ? nil : binding
                            }
                        }
                    )
                    .padding(.top, 8)
                    Text(draft.shortcut?.displayName ?? "No shortcut")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let message = draft.validationMessage ?? saveMessage {
                        Label(message, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.top, 8)
                    }
                }
            }
            .frame(maxHeight: 560)

            HStack {
                Button("Cancel") {
                    isPresented = false
                    transform = nil
                }
                Spacer()
                Button("Save") {
                    if let message = appState.saveCustomTransform(draft) {
                        saveMessage = message
                    } else {
                        isPresented = false
                        transform = nil
                    }
                }
                .disabled(draft.validationMessage != nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let transform {
                draft = transform
            }
        }
        .onChange(of: isCapturingShortcut) { isCapturing in
            if isCapturing {
                appState.suspendHotkeyMonitoringForShortcutCapture()
            } else {
                appState.resumeHotkeyMonitoringAfterShortcutCapture()
            }
        }
        .onDisappear {
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
        }
    }

    private var instructionWordCount: Int {
        TransformCore.wordCount(draft.instructions)
    }

    /// A guarded binding: a Remove mid-update must not index past the shortened array.
    private func sampleEditor(at index: Int) -> some View {
        let text = Binding<String>(
            get: { index < draft.samples.count ? draft.samples[index] : "" },
            set: { if index < draft.samples.count { draft.samples[index] = $0 } }
        )
        let wordCount = TransformCore.wordCount(text.wrappedValue)
        return VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: text)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            HStack {
                Text("\(wordCount) words (\(CustomTransform.sampleWordRange.lowerBound)–\(CustomTransform.sampleWordRange.upperBound))")
                    .font(.caption)
                    .foregroundStyle(CustomTransform.sampleWordRange.contains(wordCount) ? Color.secondary : Color.red)
                Spacer()
                Button("Remove") {
                    if index < draft.samples.count {
                        draft.samples.remove(at: index)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }
}
