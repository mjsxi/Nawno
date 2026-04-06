import SwiftUI

struct SetupSheet: View {
    @Environment(LLMService.self) private var llm

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("One-Time Setup")
                .font(.title2.bold())

            Text("NawNo needs to download Python and a few packages to run models. This only happens once.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 6) {
                Label("Python 3.12", systemImage: "checkmark.circle.fill")
                Label("mlx-lm (model inference)", systemImage: "checkmark.circle.fill")
                Label("mlx-vlm (vision models)", systemImage: "checkmark.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button {
                Task { await llm.performSetup() }
            } label: {
                Text("Install")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 400)
    }
}

struct SetupProgressOverlay: View {
    @Environment(LLMService.self) private var llm

    var body: some View {
        if llm.isSettingUp {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(llm.setupStatus.isEmpty ? "Setting up..." : llm.setupStatus)
                    .font(.headline)
                Text("This may take a minute")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
