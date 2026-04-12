//
//  AppearanceSettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var appPreferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker(selection: $appPreferences.appColorScheme) {
                    Text("system").tag(AppColorScheme.system)
                    Text("light").tag(AppColorScheme.light)
                    Text("dark").tag(AppColorScheme.dark)
                } label: {
                    Label("appearance", systemImage: "circle.lefthalf.filled")
                }
                .pickerStyle(.inline)
            }

            #if os(iOS)
            Section {
                Picker(selection: $appPreferences.appTintColor) {
                    ForEach(AppTintColor.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { option in
                        Text(String(describing: option).lowercased())
                            .tag(option)
                    }
                } label: {
                    Label("color", systemImage: "paintbrush.pointed")
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("appearance")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    AppearanceSettingsView()
}
