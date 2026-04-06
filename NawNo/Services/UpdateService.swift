import Foundation

struct AvailableUpdate: Equatable {
    let current: String
    let latest: String
    var downloadURL: URL?
}

@MainActor @Observable
final class UpdateService {
    // Update this to your GitHub repo once created (e.g. "yourusername/nawno")
    static let githubRepo = "mattnawno/nawno"

    var mlxSwiftUpdate: AvailableUpdate?
    var mlxPythonUpdate: AvailableUpdate?
    var appUpdate: AvailableUpdate?
    var isCheckingUpdates = false
    var isUpgradingPython = false
    var upgradeError: String?

    private let pythonService = PythonMLXService()

    // MARK: - Check All

    func checkForUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true

        async let swiftCheck: Void = checkMLXSwiftUpdate()
        async let pythonCheck: Void = checkMLXPythonUpdate()
        async let appCheck: Void = checkAppUpdate()

        _ = await (swiftCheck, pythonCheck, appCheck)

        isCheckingUpdates = false
    }

    // MARK: - MLX Swift (compiled dependency)

    private func checkMLXSwiftUpdate() async {
        let currentHash = MLXSwiftVersion.commitHash
        guard !currentHash.isEmpty else { return }

        guard let url = URL(string: "https://api.github.com/repos/ml-explore/mlx-swift-lm/commits/main") else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latestHash = json["sha"] as? String else { return }

            let currentShort = String(currentHash.prefix(7))
            let latestShort = String(latestHash.prefix(7))

            if currentHash != latestHash {
                mlxSwiftUpdate = AvailableUpdate(current: currentShort, latest: latestShort)
            } else {
                mlxSwiftUpdate = nil
            }
        } catch {
            // Silently fail — don't bother the user if the check fails
        }
    }

    // MARK: - Python mlx-lm

    private func checkMLXPythonUpdate() async {
        guard await PythonMLXService.isAvailable() else {
            mlxPythonUpdate = nil
            return
        }

        guard let installedVersion = await PythonMLXService.installedVersion() else { return }

        guard let url = URL(string: "https://pypi.org/pypi/mlx-lm/json") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let latestVersion = info["version"] as? String else { return }

            if installedVersion != latestVersion {
                mlxPythonUpdate = AvailableUpdate(current: installedVersion, latest: latestVersion)
            } else {
                mlxPythonUpdate = nil
            }
        } catch {
            // Silently fail
        }
    }

    func upgradePython() async {
        isUpgradingPython = true
        upgradeError = nil

        do {
            try await pythonService.installMLXLM()
            mlxPythonUpdate = nil
            PythonMLXService.clearCache()
        } catch {
            upgradeError = error.localizedDescription
        }

        isUpgradingPython = false
    }

    // MARK: - NawNo App

    private func checkAppUpdate() async {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }

        guard let url = URL(string: "https://api.github.com/repos/\(UpdateService.githubRepo)/releases/latest") else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String else { return }

            let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                appUpdate = AvailableUpdate(
                    current: currentVersion,
                    latest: latestVersion,
                    downloadURL: URL(string: htmlURL)
                )
            } else {
                appUpdate = nil
            }
        } catch {
            // Silently fail
        }
    }
}
