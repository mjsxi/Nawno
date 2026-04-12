//
//  ChatsSettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/6/24.
//

import SwiftUI

struct ChatsSettingsView: View {
    @EnvironmentObject private var appPreferences: AppPreferences
    @Environment(\.modelContext) var modelContext
    @Bindable var chatSession: ChatSessionController
    @State private var deleteAllChats = false
    @State private var deleteError: String?
    
    var body: some View {
        Form {
            Section(header: Text("auto-title chats"), footer: Text("ask the model to summarize each chat into a short title after the second message.")) {
                Picker(selection: $appPreferences.autoTitleDelay) {
                    ForEach(AutoTitleDelay.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label("delay", systemImage: "text.badge.checkmark")
                }
                .pickerStyle(.menu)
            }

            if appPreferences.userInterfaceIdiom == .phone {
                Section {
                    Toggle("haptics", isOn: $appPreferences.shouldPlayHaptics)
                        .tint(.green)
                }
            }
            
            Section {
                Button {
                    deleteAllChats.toggle()
                } label: {
                    Label("delete all chats", systemImage: "trash")
                        .themedSettingsButtonContent(color: .red)
                }
                .alert("are you sure?", isPresented: $deleteAllChats) {
                    Button("cancel", role: .cancel) {
                        deleteAllChats = false
                    }
                    Button("delete", role: .destructive) {
                        deleteChats()
                    }
                }
                .buttonStyle(.borderless)
            }

            if let deleteError {
                Section {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("chats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    func deleteChats() {
        do {
            chatSession.startNewChat()
            try modelContext.delete(model: Thread.self)
            try modelContext.delete(model: Message.self)
        } catch {
            deleteError = "couldn't delete chats: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ChatsSettingsView(chatSession: ChatSessionController())
        .environmentObject(AppPreferences())
}
