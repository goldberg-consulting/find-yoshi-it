import Carbon
import Foundation

/// Registers only Command–Space. No event tap, keyboard recording, or Accessibility grant.
@MainActor
final class GlobalSearchShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static let signature: OSType = 0x46414E59 // FANY

    init(action: @escaping () -> Void) { self.action = action }

    enum SystemShortcutStatus {
        case available
        case conflict
        case unknown(OSStatus)
    }

    /// Includes macOS defaults that are absent from the user's preferences file.
    func systemShortcutStatus() -> SystemShortcutStatus {
        var values: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&values)
        guard status == noErr, let values else { return .unknown(status) }
        for case let row as NSDictionary in values.takeRetainedValue() as NSArray {
            let code = (row[kHISymbolicHotKeyCode] as? NSNumber)?.intValue
            let modifiers = (row[kHISymbolicHotKeyModifiers] as? NSNumber)?.intValue
            let enabled = (row[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue
            if enabled == true, code == kVK_Space, modifiers == cmdKey { return .conflict }
        }
        return .available
    }

    func register() -> OSStatus {
        if hotKey != nil { return noErr }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == 0x46414E59, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<GlobalSearchShortcut>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor [weak shortcut] in shortcut?.action() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }
        // Registration can succeed while Spotlight still opens. Check system shortcuts separately.
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey), EventHotKeyID(signature: Self.signature, id: 1),
                                   GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
