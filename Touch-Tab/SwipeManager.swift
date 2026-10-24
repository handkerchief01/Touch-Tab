import Cocoa
import os.log

class SwipeManager {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Touch-Tab", category: "SwipeManager")
    private static let sensitivityKey = "sensitivity"
    static var sensitivity: Sensitivity = UserDefaults.standard.string(forKey: sensitivityKey).flatMap(Sensitivity.init(rawValue:)) ?? .medium {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: sensitivityKey)
        }
    }
    // Horizontal swipe distance (fraction of the trackpad width) to move by one app. Lower is more sensitive.
    private static var accVelXThreshold: Float {
        switch sensitivity {
        case .lowest: return 0.05
        case .low: return 0.04
        case .medium: return 0.035
        case .high: return 0.03
        case .highest: return 0.025
        }
    }
    // Vertical swipe distance (fraction of the trackpad height) to move by one row of apps. A row is a bigger jump than an app.
    private static var accVelYThreshold: Float {
        return accVelXThreshold * 2
    }
    // TODO: figure out the real value of the delay.
    private static let appSwitcherUIDelay: Double = 0.2
    // Pause after a row change, so a quick swipe up or down moves by one row only.
    private static let rowChangeDelay: Double = 0.25
    // Pause after waking up or unlocking before checking touches, so the system is done setting up the trackpad.
    private static let wakeCheckDelay: Double = 1
    // How often we check the event tap and the touch devices, because macOS may break them without telling us.
    private static let watchdogInterval: Double = 5
    // Gesture events without touches in a row after waking up, while touches worked before. About a second of using the trackpad.
    private static let emptyTouchEventsToRelaunch = 100

    private static var eventTap: CFMachPort? = nil
    private static var runLoopSource: CFRunLoopSource? = nil
    private static var wakeCheckTimer: Timer? = nil
    private static var watchdog: Timer? = nil
    private static var touchDeviceCountAtLaunch: Int? = nil
    private static var isRelaunching = false
    // Touch state, to find out when AppKit stops giving us touches.
    private static var hasReceivedTouches = false
    // No touches yet since the event tap was created or the system woke up.
    private static var isWaitingForTouches = false
    private static var isWaitingForSwitch = false
    private static var emptyTouchEvents = 0
    // Event state.
    private static var accVelX: Float = 0
    private static var accVelY: Float = 0
    private static var prevTouchPositions: [String: NSPoint] = [:]
    // Gesture state. Gesture may consists of multiple events.
    private static var startTime: Date? = nil
    private static var rowChangeTime: Date? = nil
    // Scrolling that started during the gesture, including its momentum after the gesture.
    private static var isSkippingScroll = false

    //TODO: move it somewhere else?
    private static func listener(_ eventType: EventType) {
        switch eventType {
        case .startOrContinue(.left):
            AppSwitcher.cmdShiftTab()
        case .startOrContinue(.right):
            AppSwitcher.cmdTab()
        case .startOrContinue(.up):
            AppSwitcher.cmdUp()
        case .startOrContinue(.down):
            AppSwitcher.cmdDown()
        case .end:
            AppSwitcher.selectInAppSwitcher()
        }
    }

    static func start() {
        if watchdog != nil {
            os_log("SwipeManager is already started", log: log)
            return
        }
        touchDeviceCountAtLaunch = touchDevices()?.count
        os_log("SwipeManager start, touch devices: %{public}@", log: log, touchDevicesDescription())
        createEventTap()

        // After some wakes AppKit stops giving us touches, so we check them after waking up and unlocking.
        let workspaceNotifications = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for name in workspaceNotifications {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                scheduleWakeCheck(reason: notification.name.rawValue)
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { notification in
            scheduleWakeCheck(reason: notification.name.rawValue)
        }

        watchdog = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { _ in
            check()
        }
        watchdog?.tolerance = 1
    }

    private static func createEventTap() {
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask([.gesture, .scrollWheel]).rawValue,
            callback: { proxy, type, cgEvent, userInfo in
                return SwipeManager.eventHandler(proxy: proxy, eventType: type, cgEvent: cgEvent, userInfo: userInfo)
            },
            userInfo: nil
        )
        guard let eventTap = eventTap else {
            os_log("SwipeManager couldn't create event tap", log: log, type: .error)
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isWaitingForTouches = true
        isWaitingForSwitch = true
        os_log("SwipeManager created event tap", log: log)
    }

    private static func destroyEventTap() {
        // Don't leave App Switcher open if the tap goes away in the middle of a gesture.
        if startTime != nil {
            endGesture()
            startTime = nil
        }
        clearEventState()
        rowChangeTime = nil
        isSkippingScroll = false
        emptyTouchEvents = 0

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // Waking up sends several notifications in a row, so we check once they stop coming.
    private static func scheduleWakeCheck(reason: String) {
        isWaitingForTouches = true
        isWaitingForSwitch = true
        wakeCheckTimer?.invalidate()
        wakeCheckTimer = Timer.scheduledTimer(withTimeInterval: wakeCheckDelay, repeats: false) { _ in
            wakeCheckTimer = nil
            os_log("SwipeManager woke up (%{public}@), touch devices: %{public}@", log: log, reason, touchDevicesDescription())
            check()
        }
    }

    private static func check() {
        if let countAtLaunch = touchDeviceCountAtLaunch, countAtLaunch > 0, touchDevices()?.count == 0 {
            relaunch(reason: "AppKit lost the touch devices")
            return
        }
        // Without Accessibility permission a new event tap wouldn't work either.
        if !isEventTapEnabled() && AXIsProcessTrusted() {
            os_log("SwipeManager event tap is disabled or missing, recreating it", log: log, type: .error)
            destroyEventTap()
            createEventTap()
        }
    }

    private static func isEventTapEnabled() -> Bool {
        guard let eventTap = eventTap else {
            return false
        }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }

    // AppKit keeps its own list of touch devices in every process.
    // We think touches stop after some wakes because the trackpad goes missing from it.
    private static func touchDevices() -> [Any]? {
        let selector = NSSelectorFromString("touchDevices")
        guard let touchDeviceClass = NSClassFromString("NSTouchDevice"), class_getClassMethod(touchDeviceClass, selector) != nil else {
            return nil
        }
        return (touchDeviceClass as AnyObject).perform(selector)?.takeUnretainedValue() as? [Any]
    }

    private static func touchDevicesDescription() -> String {
        guard let touchDevices = touchDevices() else {
            return "unknown"
        }
        return "\(touchDevices.count) \(touchDevices)"
    }

    // When touches are broken in this process, only a new one gets them again, like when the user relaunches the app.
    private static func relaunch(reason: String) {
        if isRelaunching {
            return
        }
        isRelaunching = true
        os_log("SwipeManager relaunches the app: %{public}@", log: log, type: .error, reason)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log("SwipeManager couldn't relaunch the app: %{public}@", log: log, type: .error, error.localizedDescription)
                    isRelaunching = false
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func eventHandler(proxy: CGEventTapProxy, eventType: CGEventType, cgEvent: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue, let nsEvent = NSEvent(cgEvent: cgEvent) {
            touchEventHandler(nsEvent)
        } else if eventType == .scrollWheel, let nsEvent = NSEvent(cgEvent: cgEvent), shouldSkipScroll(nsEvent) {
            return nil
        } else if (eventType == .tapDisabledByUserInput || eventType == .tapDisabledByTimeout), let eventTap = eventTap {
            os_log("SwipeManager event tap disabled by %{public}@, enabling it again", log: log, eventType == .tapDisabledByTimeout ? "timeout" : "user input")
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    // Two-finger scrolling moves the selection in App Switcher, so we skip it during the gesture.
    private static func shouldSkipScroll(_ nsEvent: NSEvent) -> Bool {
        if startTime != nil {
            isSkippingScroll = true
        } else if nsEvent.phase == .began || nsEvent.phase == .mayBegin || (nsEvent.phase == [] && nsEvent.momentumPhase == []) {
            // A new scroll or a mouse wheel isn't a leftover of the gesture.
            isSkippingScroll = false
        }
        return isSkippingScroll
    }

    private static func touchEventHandler(_ nsEvent: NSEvent) {
        let touches = nsEvent.allTouches()

        // Sometimes there are empty touch events that we have to skip. There are no empty touch events if Mission Control or App Expose use 3-finger swipes though.
        if touches.isEmpty {
            emptyTouchEvents += 1
            if emptyTouchEvents == emptyTouchEventsToRelaunch {
                os_log("SwipeManager got %ld gesture events in a row without touches, touch devices: %{public}@", log: log, emptyTouchEvents, touchDevicesDescription())
                // Touches worked before waking up, so they are broken in this process.
                if hasReceivedTouches && isWaitingForTouches {
                    relaunch(reason: "no touches after waking up")
                }
            }
            return
        }
        if emptyTouchEvents >= emptyTouchEventsToRelaunch {
            os_log("SwipeManager got touches again after %ld gesture events without them", log: log, emptyTouchEvents)
        }
        emptyTouchEvents = 0
        hasReceivedTouches = true
        if isWaitingForTouches {
            isWaitingForTouches = false
            os_log("SwipeManager receives touches", log: log)
        }
        let touchesCount = touches.allSatisfy({ $0.phase == .ended }) ? 0 : touches.count

        switch touchesCount {
        case 2: processTwoFingers()
        case 3: processThreeFingers(touches: touches)
        default: processOtherFingers()
        }
    }

    private static func processTwoFingers() {
        // We shouldn't accumulate gesture velocity of two fingers. Their scrolling is skipped by shouldSkipScroll.
        clearEventState()
    }

    private static func processThreeFingers(touches: Set<NSTouch>) {
        // We don't care about swipes where fingers don't move together.
        guard let swipe = swipeVelocity(touches: touches) else {
            return
        }

        switch swipe {
        case .horizontal(let velX):
            processHorizontalSwipe(velX: velX)
        case .vertical(let velY):
            processVerticalSwipe(velY: velY)
        }
    }

    private static func processHorizontalSwipe(velX: Float) {
        // Changing direction starts counting from scratch.
        if (velX < 0) != (accVelX < 0) {
            accVelX = 0
        }
        accVelX += velX
        // Every accVelXThreshold of swiping is one app, so a fast swipe may move by several apps at once.
        while abs(accVelX) >= accVelXThreshold {
            if startTime == nil {
                startTime = Date()
            } else {
                let interval = startTime!.timeIntervalSinceNow
                if -interval < appSwitcherUIDelay {
                    // We skip subsequent events until App Switcher UI is shown.
                    accVelX = 0
                    return
                }
            }

            startOrContinueGesture(direction: accVelX < 0 ? .left : .right)
            // Keep the swiping beyond the threshold for the next app instead of throwing it away.
            accVelX -= Float(signOf: accVelX, magnitudeOf: accVelXThreshold)
            // A horizontal swipe drifting up or down shouldn't add up to a row change.
            accVelY = 0
        }
    }

    private static func processVerticalSwipe(velY: Float) {
        // Rows can be changed only when App Switcher UI is shown. Otherwise it's a Mission Control or App Exposé swipe.
        if startTime == nil || -startTime!.timeIntervalSinceNow < appSwitcherUIDelay {
            return
        }
        if rowChangeTime != nil && -rowChangeTime!.timeIntervalSinceNow < rowChangeDelay {
            // We skip the rest of a quick swipe that has already changed the row.
            accVelY = 0
            return
        }

        // Changing direction starts counting from scratch.
        if (velY < 0) != (accVelY < 0) {
            accVelY = 0
        }
        accVelY += velY
        // Not enough swiping.
        if abs(accVelY) < accVelYThreshold {
            return
        }

        // Trackpad Y grows upwards.
        startOrContinueGesture(direction: accVelY < 0 ? .down : .up)
        rowChangeTime = Date()
        accVelX = 0
        accVelY = 0
    }

    private static func processOtherFingers() {
        if startTime != nil {
            endGesture()
            clearEventState()
            startTime = nil
        }
    }

    private static func clearEventState() {
        accVelX = 0
        accVelY = 0
        prevTouchPositions.removeAll()
    }

    private static func startOrContinueGesture(direction: EventType.Direction) {
        if isWaitingForSwitch {
            isWaitingForSwitch = false
            os_log("SwipeManager switched apps", log: log)
        }
        listener(.startOrContinue(direction: direction))
    }

    private static func endGesture() {
        listener(.end)
    }

    private static func swipeVelocity(touches: Set<NSTouch>) -> Swipe? {
        var allRight = true
        var allLeft = true
        var allUp = true
        var allDown = true
        var sumVelX = Float(0)
        var sumVelY = Float(0)
        for touch in touches {
            let (velX, velY) = touchVelocity(touch)
            allRight = allRight && velX >= 0
            allLeft = allLeft && velX <= 0
            allUp = allUp && velY >= 0
            allDown = allDown && velY <= 0
            sumVelX += velX
            sumVelY += velY

            if touch.phase == .ended {
                prevTouchPositions.removeValue(forKey: "\(touch.identity)")
            } else {
                prevTouchPositions["\(touch.identity)"] = touch.normalizedPosition
            }
        }

        let velX = sumVelX / Float(touches.count)
        let velY = sumVelY / Float(touches.count)
        // A swipe goes along its main axis, and all fingers should move in the same direction.
        if abs(velX) > abs(velY) {
            return allRight || allLeft ? .horizontal(velX) : nil
        } else if abs(velY) > abs(velX) {
            return allUp || allDown ? .vertical(velY) : nil
        }
        return nil
    }
    
    private static func touchVelocity(_ touch: NSTouch) -> (Float, Float) {
        guard let prevPosition = prevTouchPositions["\(touch.identity)"] else {
            return (0, 0)
        }
        let position = touch.normalizedPosition
        return (Float(position.x - prevPosition.x), Float(position.y - prevPosition.y))
    }

    enum EventType {
        case startOrContinue(direction: Direction)
        case end

        enum Direction {
            case left
            case right
            case up
            case down
        }
    }

    private enum Swipe {
        case horizontal(Float)
        case vertical(Float)
    }

    enum Sensitivity: String, CaseIterable {
        case lowest, low, medium, high, highest
    }
}
