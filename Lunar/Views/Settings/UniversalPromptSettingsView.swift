//
//  UniversalPromptSettingsView.swift
//  Lunar
//

import SwiftUI

struct UniversalPromptSettingsView: View {
    @EnvironmentObject private var appPreferences: AppPreferences

    var body: some View {
        Form {
            Section(footer: Text("used by any model that doesn't set its own system prompt")) {
                TextEditor(text: $appPreferences.systemPrompt)
                    .textEditorStyle(.plain)
                    .frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("universal prompt")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
