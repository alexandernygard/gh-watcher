import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A system-wide keyboard shortcut. Carbon hot keys work without Accessibility permission.
struct Hotkey: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value (device-independent part only).
    var modifiers: UInt
    /// Key as typed when recorded, e.g. "G".
    var key: String

    static let defaultMenu = Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, key: "G")
    static let defaultQuickOpen = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, key: "K")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }
}

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    enum Slot: UInt32 { case menuBar = 1, quickOpen = 2 }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    /// Slots whose shortcut is already taken by another app.
    private(set) var conflicts: Set<Slot> = []

    func apply(_ prefs: Preferences) {
        set(.menuBar, prefs.menuHotkey) { HotkeyCenter.toggleMenuBarPanel() }
        set(.quickOpen, prefs.quickOpenHotkey) {
            let store = AppStore.shared
            store.activateMainWindow()
            store.showQuickOpen = true
        }
    }

    private func set(_ slot: Slot, _ hotkey: Hotkey?, action: @escaping () -> Void) {
        if let ref = refs.removeValue(forKey: slot.rawValue) { UnregisterEventHotKey(ref) }
        conflicts.remove(slot)
        actions[slot.rawValue] = action
        guard let hotkey else { return }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4748_5754), id: slot.rawValue) // 'GHWT'
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[slot.rawValue] = ref } else { conflicts.insert(slot) }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let slot = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(slot) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Opens (or closes) the MenuBarExtra panel by clicking its status item.
    static func toggleMenuBarPanel() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let button = window.contentView.flatMap(findButton) {
                button.performClick(nil)
                return
            }
        }
        AppStore.shared.activateMainWindow()
    }

    private static func findButton(_ view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = findButton(sub) { return found } }
        return nil
    }
}

/// Click, then press a key combination. Esc cancels, Delete clears.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut…" : hotkey?.display ?? "Record Shortcut")
                    .monospaced(!recording && hotkey != nil)
                    .frame(minWidth: 110)
            }
            if hotkey != nil && !recording {
                Button { hotkey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete, kVK_ForwardDelete: hotkey = nil; stop()
            default:
                guard !flags.intersection([.command, .option, .control]).isEmpty,
                      let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { NSSound.beep(); return nil }
                hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, key: key == " " ? "Space" : key)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
