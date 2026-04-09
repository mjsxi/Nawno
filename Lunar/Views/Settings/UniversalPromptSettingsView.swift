//
//  UniversalPromptSettingsView.swift
//  Lunar
//

import SwiftUI

struct UniversalPromptSettingsView: View {
    @EnvironmentObject var appManager: AppManager

    var body: some View {
        Form {
            Section(footer: Text("used by any model that doesn't set its own system prompt")) {
                TextEditor(text: $appManager.systemPrompt)
                    .textEditorStyle(.plain)
                    .frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("universal prompt")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
