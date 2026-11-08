// DALI — ticks speakers in Apple's AirPlay list by name, so Play stays one click.
//
// macOS offers an app no call to choose AirPlay speakers, only its own list. That
// list is exposed through accessibility like any control (rows with a name and a
// checkbox), so DALI reads the names and presses the boxes it wants, the same
// press VoiceOver would make. It only ever touches DALI's own AirPlay list.
// Needs DALI to be allowed under Privacy & Security > Accessibility, once.

import AppKit
import ApplicationServices

enum PickerAutomation {
    struct Row {
        let name: String
        let checkbox: AXUIElement
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow DALI to control this computer" prompt.
    static func requestTrust() {
        // The documented key, spelled out: the C global is not concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: reading and pressing

    /// The rows of the AirPlay list that is open under `root` (DALI itself by default).
    static func rows(in root: AXUIElement = AXUIElementCreateApplication(getpid())) -> [Row] {
        var result: [Row] = []
        // DALI has several popovers; only the AirPlay list has rows.
        collect(root, depth: 0) { row in
            // A row holds a cell, and the cell holds the name and the checkbox.
            guard let label = find(row, role: "AXStaticText", depth: 0), let name = text(label),
                  let box = find(row, role: "AXCheckBox", depth: 0) else { return }
            result.append(Row(name: name, checkbox: box))
        }
        return result
    }

    /// True once the list is open and its rows are readable.
    static func isListOpen(in root: AXUIElement = AXUIElementCreateApplication(getpid())) -> Bool {
        !rows(in: root).isEmpty
    }

    /// Presses the boxes of speakers named in `names` (case-insensitive, same
    /// apostrophes). Returns the names pressed.
    @discardableResult
    static func tick(names: [String], in root: AXUIElement = AXUIElementCreateApplication(getpid())) -> [String] {
        var pressed: [String] = []
        let available = rows(in: root)
        for wanted in names {
            guard let row = available.first(where: { normalized($0.name) == normalized(wanted) }) else { continue }
            if AXUIElementPerformAction(row.checkbox, kAXPressAction as CFString) == .success {
                pressed.append(row.name)
            }
        }
        return pressed
    }

    /// Closes the list by pressing the button that owns it.
    static func closeList(in root: AXUIElement = AXUIElementCreateApplication(getpid())) {
        guard let row = rows(in: root).first,
              var node = attribute(row.checkbox, kAXParentAttribute as String) else { return }
        // Walk up from a row to its popover, then press the button that owns it.
        for _ in 0..<10 {
            let element = node as! AXUIElement
            if role(element) == "AXPopover" {
                if let owner = attribute(element, kAXParentAttribute as String) {
                    _ = AXUIElementPerformAction(owner as! AXUIElement, kAXPressAction as CFString)
                }
                return
            }
            guard let up = attribute(element, kAXParentAttribute as String) else { return }
            node = up
        }
    }

    // MARK: accessibility helpers

    private static func normalized(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as AnyObject?
    }

    private static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute as String) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func text(_ element: AXUIElement) -> String? {
        (attribute(element, kAXValueAttribute as String) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func collect(_ element: AXUIElement, depth: Int, visit: (AXUIElement) -> Void) {
        guard depth < 30 else { return }
        if role(element) == "AXRow" { visit(element); return }
        for child in children(element) { collect(child, depth: depth + 1, visit: visit) }
    }

    private static func find(_ element: AXUIElement, role wanted: String, depth: Int) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if role(element) == wanted { return element }
        for child in children(element) {
            if let hit = find(child, role: wanted, depth: depth + 1) { return hit }
        }
        return nil
    }
}
