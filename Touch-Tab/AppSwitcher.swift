import Cocoa

class AppSwitcher {
    private static let keyboardEventSource = CGEventSource(stateID: CGEventSourceStateID.hidSystemState)
    private static let tabKey = CGKeyCode(0x30);
    private static let leftCommandKey = CGKeyCode(0x37);
    private static let downArrowKey = CGKeyCode(0x7D);
    private static let upArrowKey = CGKeyCode(0x7E);

    static func selectInAppSwitcher() {
        postKeyEvent(key: leftCommandKey, down: false)
    }

    static func cmdTab() {
        postKeyEvent(key: tabKey, down: true, flags: .maskCommand)
        postKeyEvent(key: tabKey, down: false, flags: .maskCommand)
    }

    static func cmdShiftTab() {
        postKeyEvent(key: tabKey, down: true, flags: [.maskCommand, .maskShift])
        postKeyEvent(key: tabKey, down: false, flags: [.maskCommand, .maskShift])
    }

    // Up and Down arrows move between rows in switchers with a grid, like Vorssaint's.
    // The system App Switcher has a single row and shows the selected app's windows instead.
    static func cmdUp() {
        postKeyEvent(key: upArrowKey, down: true, flags: .maskCommand)
        postKeyEvent(key: upArrowKey, down: false, flags: .maskCommand)
    }

    static func cmdDown() {
        postKeyEvent(key: downArrowKey, down: true, flags: .maskCommand)
        postKeyEvent(key: downArrowKey, down: false, flags: .maskCommand)
    }

    private static func postKeyEvent(key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
