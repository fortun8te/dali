// Apply the approved DALI icon to an installed app as a macOS custom icon.
//
//   swiftc -O scripts/set-app-icon.swift -o /tmp/set-app-icon
//   /tmp/set-app-icon Assets/AppIcon.icns /Applications/DALI.app
//
// Why: macOS 26+ wraps a plain bundle icns in a grey rounded container ("icon jail")
// so the artwork looks small and framed in the Dock. A custom icon, which is what
// the 13 Oct 2026 approved look used, is drawn as-is. A fresh install replaces the
// bundle, so the custom icon must be applied again after every install. The custom
// icon is stored beside Contents (an `Icon\r` file); it does not change Contents or
// the signature (`codesign --verify --deep` passes; `--strict` objects to the file).
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let image = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: set-app-icon <icon.icns> <App.app>\n".utf8))
    exit(2)
}
let applied = NSWorkspace.shared.setIcon(image, forFile: arguments[2], options: [])
print(applied ? "custom icon applied to \(arguments[2])" : "could not apply the icon")
exit(applied ? 0 : 1)
