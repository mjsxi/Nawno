//
//  BackendRouter.swift
//  Lunar
//
//  Single source of truth for picking the inference backend for a given
//  model. Holds one shared instance per kind so model state isn't lost
//  between calls.
//

import Foundation

@MainActor
final class BackendRouter {
    static let shared = BackendRouter()

    private let mlxSwift = MLXSwiftBackend()
    #if os(macOS)
    private let python = PythonMLXBackend()
    #endif

    func backend(for kind: BackendKind) -> InferenceBackend {
        switch kind {
        case .mlxSwift:
            return mlxSwift
        case .pythonMLX:
            #if os(macOS)
            return python
            #else
            return mlxSwift // fallback; UI prevents selecting on iOS
            #endif
        }
    }
}
