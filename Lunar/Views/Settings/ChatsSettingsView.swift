//
//  ChatsSettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/6/24.
//

import SwiftUI

struct ChatsSettingsView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(\.modelContext) var modelContext
    @State var systemPrompt = ""
    @State var deleteAllChats = false
    @Binding var currentThread: Thread?
    
    var body: some View {
        Form {
            Section(header: Text("auto-title chats"), footer: Text("ask the model to summarize each chat into a short title after the second message.")) {
                Picker(selection: $appManager.autoTitleDelay) {
                    ForEach(AutoTitleDelay.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Label("delay", systemImage: "text.badge.checkmark")
                }
                .pickerStyle(.menu)
            }

            if appManager.userInterfaceIdiom == .phone {
                Section {
                    Toggle("haptics", isOn: $appManager.shouldPlayHaptics)
                        .tint(.green)
                }
            }
            
            Section {
                Button {
                    deleteAllChats.toggle()
                } label: {
                    Label("delete all chats", systemImage: "trash")
                        .foregroundStyle(.red)
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
        }
        .formStyle(.grouped)
        .navigationTitle("chats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    func deleteChats() {
        do {
            currentThread = nil
            try modelContext.delete(model: Thread.self)
            try modelContext.delete(model: Message.self)
        } catch {
            print("Failed to delete.")
        }
    }
}

#Preview {
    ChatsSettingsView(currentThread: .constant(nil))
}
