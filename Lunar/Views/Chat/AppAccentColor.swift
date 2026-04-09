//
//  AppAccentColor.swift
//  Lunar
//
//  Resolves to the user's OS-level accent color (System Settings → Appearance
//  → Accent color on macOS) instead of the bundled AccentColor asset.
//

import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension Color {
    static var appAccent: Color {
        #if os(macOS)
        return Color(nsColor: .controlAccentColor)
        #elseif os(iOS)
        return Color(uiColor: .tintColor)
        #else
        return .accentColor
        #endif
    }
}
