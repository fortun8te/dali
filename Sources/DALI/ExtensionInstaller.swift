import Foundation

/// Chrome's unpacked install path stays fixed when the app bundle is replaced.
/// Copy only extension runtime files, never repository tests or local artifacts.
enum ExtensionInstaller {
    enum InstallError: LocalizedError {
        case missingBundle, invalidManifest
        var errorDescription: String? {
            switch self {
            case .missingBundle: "This build is missing the browser extension. Download the complete DALI release and try again."
            case .invalidManifest: "The bundled browser extension is incomplete. Download the complete DALI release and try again."
            }
        }
    }

    static var installURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DALI/ChromeExtension", isDirectory: true)
    }

    static var bundledURL: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let url = root.appendingPathComponent("ChromeExtension", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
    }

    /// Established users opt into the managed copy by revealing it once.
    /// Launches before that point do not create or relocate their extension.
    static func updateExistingInstall() throws {
        guard FileManager.default.fileExists(atPath: installURL.path) else { return }
        _ = try install()
    }

    @discardableResult
    static func install(from source: URL? = bundledURL, to destination: URL = installURL) throws -> URL {
        guard let source else { throw InstallError.missingBundle }
        let fm = FileManager.default
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["manifest_version"] as? Int == 3,
              manifest["version"] is String,
              fm.fileExists(atPath: source.appendingPathComponent("background.js").path),
              fm.fileExists(atPath: source.appendingPathComponent("content.js").path),
              fm.fileExists(atPath: source.appendingPathComponent("beacon.js").path)
        else { throw InstallError.invalidManifest }

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".ChromeExtension-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        let runtimeNames = ["manifest.json", "background.js", "content.js", "beacon.js", "icons", "LICENSE"]
        for name in runtimeNames {
            let file = source.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) {
                try fm.copyItem(at: file, to: staged.appendingPathComponent(name))
            }
        }
        if fm.fileExists(atPath: destination.path) {
            // Do not rewrite unchanged resources every time DALI opens.
            let changed = runtimeNames.contains { name in
                let old = destination.appendingPathComponent(name)
                let new = staged.appendingPathComponent(name)
                return !fm.contentsEqual(atPath: old.path, andPath: new.path)
                    && (fm.fileExists(atPath: old.path) || fm.fileExists(atPath: new.path))
            }
            guard changed else { return destination }
            _ = try fm.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        return destination
    }
}
