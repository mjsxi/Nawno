//
//  ChatsListView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import StoreKit
import SwiftData
import SwiftUI

struct ChatsListView: View {
    @EnvironmentObject private var appPreferences: AppPreferences
    @Environment(\.dismiss) var dismiss
    @Bindable var chatSession: ChatSessionController
    @FocusState.Binding var isPromptFocused: Bool
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Thread.timestamp, order: .reverse) var threads: [Thread]
    @State private var search = ""
    @State private var selection: Thread?

    @Environment(\.requestReview) private var requestReview

    private var filteredThreads: [Thread] {
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else { return threads }
        return threads.filter { thread in
            thread.sortedMessages.contains { message in
                message.content.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                List(selection: $selection) {
                    #if os(macOS)
                    Section {} // adds some space below the search bar on mac
                    #endif
                    ForEach(filteredThreads, id: \.id) { thread in
                        VStack(alignment: .leading) {
                            Text(threadDisplayTitle(thread))
                                .lineLimit(1)
                                .contentTransition(.opacity)
                                .animation(.easeInOut(duration: 0.45), value: thread.title)
                                .foregroundStyle(.primary)
                                .font(.headline)

                            Text("\(thread.timestamp.formatted())")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        #if os(macOS)
                            .swipeActions {
                                Button("Delete") {
                                    deleteThread(thread)
                                }
                                .tint(.red)
                            }
                            .contextMenu {
                                Button {
                                    deleteThread(thread)
                                } label: {
                                    Text("delete")
                                }
                            }
                        #endif
                            .tag(thread)
                    }
                    .onDelete(perform: deleteThreads)
                }
                .onAppear {
                    selection = chatSession.currentThread
                }
                .onChange(of: chatSession.currentThread?.id) {
                    selection = chatSession.currentThread
                }
                .onChange(of: selection) {
                    setCurrentThread(selection)
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #elseif os(macOS)
                .listStyle(.sidebar)
                #endif
                if filteredThreads.count == 0 {
                    if threads.count == 0 {
                        Image(.lilChat)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .opacity(0.8)
                            .offset(y: -16)
                    } else {
                        ContentUnavailableView {
                            Label("no results", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
            .navigationTitle("chats")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "search")
            #elseif os(macOS)
                .searchable(text: $search, placement: .sidebar, prompt: "search")
            #endif
                .toolbar {
                    #if os(iOS)
                    if appPreferences.userInterfaceIdiom == .phone {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark")
                            }
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            selection = nil
                            setCurrentThread(nil)
                            requestReviewIfAppropriate()
                        }) {
                            Image(systemName: "plus")
                        }
                        .keyboardShortcut("N", modifiers: [.command])
                    }
                    #elseif os(macOS)
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            selection = nil
                            setCurrentThread(nil)
                            requestReviewIfAppropriate()
                        }) {
                            Label("new", systemImage: "plus")
                        }
                        .keyboardShortcut("N", modifiers: [.command])
                    }
                    #endif
                }
        }
        .tint(appPreferences.appTintColor.getColor())
        .environment(\.dynamicTypeSize, appPreferences.appFontSize.getFontSize())
    }

    private func threadDisplayTitle(_ thread: Thread) -> String {
        if let title = thread.title, !title.isEmpty { return title }
        if let firstMessage = thread.sortedMessages.first { return firstMessage.content }
        return "untitled"
    }

    func requestReviewIfAppropriate() {
        if appPreferences.numberOfVisits - appPreferences.numberOfVisitsOfLastRequest >= 5 {
            requestReview() // can only be prompted if the user hasn't given a review in the last year, so it will prompt again when apple deems appropriate
            appPreferences.numberOfVisitsOfLastRequest = appPreferences.numberOfVisits
        }
    }

    private func deleteThreads(at offsets: IndexSet) {
        for offset in offsets {
            let thread = threads[offset]

            if let currentThread = chatSession.currentThread, currentThread.id == thread.id {
                setCurrentThread(nil)
            }

            let delay = appPreferences.userInterfaceIdiom == .phone ? 1_000_000_000 : 0
            Task { @MainActor in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }
                modelContext.delete(thread)
            }
        }
    }

    private func deleteThread(_ thread: Thread) {
        if let currentThread = chatSession.currentThread, currentThread.id == thread.id {
            setCurrentThread(nil)
        }
        modelContext.delete(thread)
    }

    private func setCurrentThread(_ thread: Thread? = nil) {
        chatSession.selectThread(thread)
        isPromptFocused = true
        #if os(iOS)
        dismiss()
        #endif
        appPreferences.playHaptic()
    }
}

#Preview {
    @FocusState var isPromptFocused: Bool
    ChatsListView(chatSession: ChatSessionController(), isPromptFocused: $isPromptFocused)
        .environmentObject(AppPreferences())
}
