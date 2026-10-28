import SwiftUI

/// Settings → Vibe coding: Wispr-style File Tagging for Cursor and Windsurf. Variable
/// recognition has no toggle of its own; it follows Context awareness.
struct VibeCodingSettingsSection: View {
    @EnvironmentObject var appState: AppState

    /// Tagging uses the file names that Context awareness reads, like the cursor fit.
    private var isUnavailable: Bool {
        !appState.contextAwarenessEnabled || appState.screenshotContextEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Convert spoken file names to @-mentions in Cursor and Windsurf",
                isOn: $appState.vibeCodingFileTaggingEnabled
            )
            .disabled(isUnavailable)

            Text("Say \"tag\" or \"at\" before a file name in Cursor or Windsurf chat. FreeFlow also picks up visible variable and function names so they are spelled right. Turn on your editor's screen reader optimized mode (Accessibility Support: on) so FreeFlow can read them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isUnavailable {
                Text("Needs Context awareness on, and is unavailable with the legacy screenshot context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
