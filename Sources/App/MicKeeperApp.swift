// MicKeeper.app: settings window for the mickeeperd background agent.
// Runs only while the window is open; the agent does the actual work. Only the agent changes the input device and
// its level: the window saves settings and lets the agent apply them, so the two never race.
import CoreAudio
import ServiceManagement
import SwiftUI
import UserNotifications
import os.log

private let updateLog = OSLog(subsystem: "io.github.fratayaydn.mickeeper", category: "updater")

// Each callback owns its reply until completion, including after a timeout. The semaphore publishes the result.
final class NotificationReply<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func complete(_ result: Result<Value, Error>) {
        self.result = result
        done.signal()
    }

    func wait(_ step: String, deadline: DispatchTime = .now() + 30) throws -> Value {
        guard done.wait(timeout: deadline) == .success, let result else {
            os_log("%{public}@ timed out", log: updateLog, type: .error, step)
            throw NSError(domain: "MicKeeper.NotificationTimeout", code: 1)
        }
        return try result.get()
    }
}

private func notificationStatus(_ center: UNUserNotificationCenter) throws -> UNAuthorizationStatus {
    let reply = NotificationReply<UNAuthorizationStatus>()
    center.getNotificationSettings { reply.complete(.success($0.authorizationStatus)) }
    return try reply.wait("Notification settings")
}

private func authorizeUpdateNotifications() throws {
    let reply = NotificationReply<Bool>()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error { reply.complete(.failure(error)) }
        else { reply.complete(.success(granted)) }
    }
    _ = try reply.wait("Notification authorization")
}

private func postUpdateNotification(_ request: UNNotificationRequest) throws {
    let reply = NotificationReply<Void>()
    UNUserNotificationCenter.current().add(request) { error in
        if let error { reply.complete(.failure(error)) }
        else { reply.complete(.success(())) }
    }
    try reply.wait("Post notification")
}

func notifyUpdate(
    _ arguments: [String],
    status: () throws -> UNAuthorizationStatus = { try notificationStatus(.current()) },
    authorize: () throws -> Void = authorizeUpdateNotifications,
    post: (UNNotificationRequest) throws -> Void = postUpdateNotification
) -> Int32 {
    guard arguments.count == 4, arguments[1] == "--notify-update",
          arguments[3] == "--installed" || arguments[3] == "--available" else { return 2 }
    let version = arguments[2]
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), parts.allSatisfy({ part in
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
    }) else { return 2 }

    do {
        var authorization = try status()
        if authorization == .notDetermined {
            try authorize()
            authorization = try status()
        }
        guard authorization == .authorized || authorization == .provisional else {
            os_log("Notifications are not allowed", log: updateLog, type: .info)
            return 0
        }
        let installed = arguments[3] == "--installed"
        let content = UNMutableNotificationContent()
        content.title = installed ? "MicKeeper updated to \(version)"
            : "MicKeeper \(version) is available"
        content.body = installed ? "The update was installed successfully." : "Open settings to install the update."
        let request = UNNotificationRequest(identifier: "release-update", content: content, trigger: nil)
        try post(request)
        os_log("Release notification posted", log: updateLog, type: .info)
        return 0
    } catch {
        let error = error as NSError
        os_log("Release notification failed: %{public}@ %ld", log: updateLog, type: .error, error.domain, error.code)
        return 1
    }
}

let agentPlistName = "io.github.fratayaydn.mickeeper.agent.plist"
let updaterPlistName = "io.github.fratayaydn.mickeeper.updater.plist"
let updaterJob = "gui/\(getuid())/io.github.fratayaydn.mickeeper.updater"
let agentJob = "gui/\(getuid())/io.github.fratayaydn.mickeeper.agent"
let settingsChangedNotification = Notification.Name("io.github.fratayaydn.mickeeper.SettingsChanged")
let statusChangedNotification = Notification.Name("io.github.fratayaydn.mickeeper.StatusChanged")
let preferredKey = "PreferredInput"
let lockLevelKey = "LockLevel"
let lockedLevelsKey = "LockedLevels"
let hiFiCountKey = "HiFiCount", hiFiLastKey = "HiFiLast"
let iPhoneCountKey = "ContinuityCount", iPhoneLastKey = "ContinuityLast"
let levelCountKey = "LevelCount", levelLastKey = "LevelLast"
let registeredBuildKey = "RegisteredBuildID"
let currentBuildID = Bundle.main.object(forInfoDictionaryKey: "MKBuildID") as? String ?? ""

// MARK: - Audio devices

struct Mic: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let kind: String
}

/// The input devices and their level, read through the same CoreAudio properties the agent uses.
enum Audio {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let defaultInputAddress = address(kAudioHardwarePropertyDefaultInputDevice)
    static let devicesAddress = address(kAudioHardwarePropertyDevices)

    static func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func float32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func defaultInput() -> AudioDeviceID { uint32(system, defaultInputAddress) ?? AudioDeviceID(kAudioObjectUnknown) }

    static func devices() -> [AudioDeviceID] {
        var address = devicesAddress
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func name(_ device: AudioDeviceID) -> String { string(device, kAudioObjectPropertyName) ?? "Unknown" }
    static func uid(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func transport(_ device: AudioDeviceID) -> UInt32 { uint32(device, address(kAudioDevicePropertyTransportType)) ?? 0 }

    static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func isHeadset(_ device: AudioDeviceID) -> Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(device))
    }

    /// Same rule as the agent: not a Bluetooth headset, an iPhone's Continuity microphone, AirPlay, or a virtual
    /// or aggregate device.
    static func isRealMic(_ device: AudioDeviceID) -> Bool {
        guard hasInput(device) else { return false }
        let excluded: [UInt32] = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                                  kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                                  kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeAirPlay,
                                  kAudioDeviceTransportTypeContinuityCaptureWired,
                                  kAudioDeviceTransportTypeContinuityCaptureWireless, kAudioDeviceTransportTypeUnknown]
        return !excluded.contains(transport(device))
    }

    /// What kind of microphone a device is, as shown in the list.
    static func kind(_ device: AudioDeviceID) -> String {
        switch transport(device) {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "Virtual"
        default: return "External"
        }
    }

    /// Every microphone, any kind: choosing one in the list is also how to use AirPods or an iPhone on purpose.
    static func allMics() -> [Mic] {
        devices().filter(hasInput).compactMap { d in uid(d).map { Mic(id: d, uid: $0, name: name(d), kind: kind(d)) } }
    }

    /// The input level, from the main element or the first channel that has one.
    static func levelAddresses(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        var main = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
        if AudioObjectHasProperty(device, &main) { return [main] }
        return (1...8).map { address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, $0) }
            .filter { var a = $0; return AudioObjectHasProperty(device, &a) }
    }

    static func level(_ device: AudioDeviceID) -> Double? {
        levelAddresses(device).lazy.compactMap { float32(device, $0) }.first.map(Double.init)
    }
}

/// "just now" under a minute, then the largest whole unit: "3 minutes ago", "1 hour ago", "2 days ago", "1 month ago".
func timeAgo(_ date: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    let units: [(seconds: Double, name: String)] = [
        (365 * 86400, "year"), (30 * 86400, "month"), (86400, "day"), (3600, "hour"), (60, "minute"),
    ]
    guard let unit = units.first(where: { seconds >= $0.seconds }) else { return "just now" }
    let count = Int(seconds / unit.seconds)
    return "\(count) \(unit.name)\(count == 1 ? "" : "s") ago"
}

func percent(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

// MARK: - Model

final class Model: ObservableObject {
    @Published var agentStatus = SMAppService.Status.notRegistered
    @Published var preferredUID: String?
    @Published var lockLevel = false
    @Published var lockedLevels: [String: Double] = [:]
    @Published var mics: [Mic] = []
    @Published var input: AudioDeviceID = 0
    @Published var inputName = ""
    @Published var inputLevel: Double?
    @Published var hiFiCount = 0
    @Published var hiFiLast: Date?
    @Published var iPhoneCount = 0
    @Published var iPhoneLast: Date?
    @Published var levelCount = 0
    @Published var levelLast: Date?

    @Published var errorMessage: String?
    @Published var automaticUpdates = true
    @Published var checkingUpdates = false
    @Published var latestVersion: String?
    @Published var lastUpdateCheck: Date?
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    // The app's bundle identifier is the agent's preferences domain, so its standard defaults are those settings.
    private let defaults = UserDefaults.standard
    private let agent = SMAppService.agent(plistName: agentPlistName)
    private var watchedInput = AudioDeviceID(kAudioObjectUnknown)
    private lazy var audioChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.readAudio() }

    init() {
        reregisterAfterUpdate()
        readSettings()
        readAgentState()
        readAudio()
        // Event-driven like the agent: CoreAudio reports device, input and level changes while the window is open.
        for var address in [Audio.defaultInputAddress, Audio.devicesAddress] {
            AudioObjectAddPropertyListenerBlock(Audio.system, &address, .main, audioChanged)
        }
        DistributedNotificationCenter.default().addObserver(forName: statusChangedNotification, object: nil, queue: .main) {
            [weak self] _ in self?.readAgentState()
        }
    }

    func readSettings() {
        preferredUID = defaults.string(forKey: preferredKey)
        lockLevel = defaults.bool(forKey: lockLevelKey)
        lockedLevels = defaults.dictionary(forKey: lockedLevelsKey) as? [String: Double] ?? [:]
    }

    func readAgentState() {
        agentStatus = agent.status
        defaults.synchronize()
        automaticUpdates = defaults.object(forKey: "AutomaticallyInstallUpdates") == nil
            || defaults.bool(forKey: "AutomaticallyInstallUpdates")
        latestVersion = defaults.string(forKey: "LatestVersion")
        lastUpdateCheck = defaults.object(forKey: "LastUpdateCheck") as? Date
        hiFiCount = defaults.integer(forKey: hiFiCountKey)
        hiFiLast = defaults.object(forKey: hiFiLastKey) as? Date
        iPhoneCount = defaults.integer(forKey: iPhoneCountKey)
        iPhoneLast = defaults.object(forKey: iPhoneLastKey) as? Date
        levelCount = defaults.integer(forKey: levelCountKey)
        levelLast = defaults.object(forKey: levelLastKey) as? Date
    }

    func readAudio() {
        mics = Audio.allMics()
        let device = Audio.defaultInput()
        if device != watchedInput {
            for var address in Audio.levelAddresses(watchedInput) where watchedInput != kAudioObjectUnknown {
                AudioObjectRemovePropertyListenerBlock(watchedInput, &address, .main, audioChanged)
            }
            for var address in Audio.levelAddresses(device) {
                AudioObjectAddPropertyListenerBlock(device, &address, .main, audioChanged)
            }
            watchedInput = device
        }
        input = device
        inputName = Audio.name(device)
        inputLevel = Audio.level(device)
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(settingsChangedNotification, object: nil, deliverImmediately: true)
    }

    func setPreferred(_ uid: String?) { preferredUID = uid; save(uid, preferredKey) }

    func setLockLevel(_ on: Bool) {
        // Locking starts from the level the microphone has now.
        if on, let uid = Audio.uid(input), lockedLevels[uid] == nil, let level = inputLevel {
            lockedLevels[uid] = level
            defaults.set(lockedLevels, forKey: lockedLevelsKey)
        }
        lockLevel = on
        save(on, lockLevelKey)
    }

    var inputUID: String? { Audio.uid(input) }
    var lockedLevel: Double? { inputUID.flatMap { lockedLevels[$0] } }

    func setLockedLevel(_ level: Double) {
        guard let uid = inputUID else { return }
        lockedLevels[uid] = min(max(level, 0), 1)
        save(lockedLevels, lockedLevelsKey)
    }

    var isEnabled: Bool { agentStatus == .enabled || agentStatus == .requiresApproval }

    func setEnabled(_ on: Bool) {
        do {
            try setLoginItemsEnabled(on)
        } catch {
            errorMessage = "Could not \(on ? "enable" : "disable") MicKeeper: \(error.localizedDescription)"
        }
        readAgentState()
    }

    var availableVersion: String? {
        guard let latestVersion else { return nil }
        let latest = latestVersion.split(separator: ".").map(String.init)
        let current = version.split(separator: ".").map(String.init)
        for index in 0..<3 {
            let a = index < latest.count ? latest[index] : "0"
            let b = index < current.count ? current[index] : "0"
            let comparison = a.compare(b, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending ? latestVersion : nil }
        }
        return nil
    }

    var lastCheckedText: String {
        guard let lastUpdateCheck else { return "Last checked: never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastUpdateCheck, relativeTo: Date()))"
    }

    func setAutomaticUpdates(_ on: Bool) {
        defaults.set(on, forKey: "AutomaticallyInstallUpdates")
        defaults.synchronize()
        automaticUpdates = on
    }

    func checkUpdates(install: Bool = false) {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mickeeperd")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--update-check", "--force"] + (install ? ["--install"] : [])
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var message: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationReason != .exit || process.terminationStatus != 0 {
                    message = "Could not complete the update. Try again later."
                }
            } catch {
                message = "Could not check for updates: \(error.localizedDescription)"
            }
            let result = message
            DispatchQueue.main.async {
                self?.checkingUpdates = false
                self?.errorMessage = result
                self?.readAgentState()
            }
        }
    }

    /// launchd only starts the agent build that was registered when the app is signed locally (its code signature
    /// is part of the launch constraint), so after an update it is registered again, if it was enabled.
    private func reregisterAfterUpdate() {
        let updater = SMAppService.agent(plistName: updaterPlistName)
        guard defaults.string(forKey: registeredBuildKey) != currentBuildID
            || updater.status == .notRegistered || updater.status == .notFound else { return }
        defaults.set(currentBuildID, forKey: registeredBuildKey)
        guard agent.status == .enabled || agent.status == .requiresApproval else { return }
        DispatchQueue.global().async { [weak self] in
            reregisterAgent()
            if !agentIsRunning() { reregisterAgent() }  // right after an update the first pass may not take
            DispatchQueue.main.async { self?.readAgentState() }
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @StateObject private var model = Model()

    var body: some View {
        Form {
            Section {
                // Two texts in a Form row label: macOS shows the second one as the row's grey description.
                Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })) {
                    Text("Enable MicKeeper")
                    Text("Keeps AirPods, other Bluetooth headphones and iPhones off the microphone, and can lock its level.")
                }
                statusRow
            }

            Group {
                Section("Microphone") {
                    Picker(selection: Binding(get: { model.preferredUID ?? "" }, set: { model.setPreferred($0.isEmpty ? nil : $0) })) {
                        Text("Automatic").tag("")
                        Divider()
                        ForEach(model.mics) { Text("\($0.name) (\($0.kind))").tag($0.uid) }
                        if let uid = model.preferredUID, !model.mics.contains(where: { $0.uid == uid }) {
                            Text("Not connected").tag(uid)
                        }
                    } label: {
                        Text("Use")
                        Text(model.preferredUID == nil
                             ? "Any microphone you choose in macOS, except AirPods, other Bluetooth headphones and iPhones, so everything you hear stays high quality."
                             : "Always this microphone while it is connected.")
                    }

                    Toggle(isOn: Binding(get: { model.lockLevel }, set: { model.setLockLevel($0) })) {
                        Text("Lock the level")
                        Text("Apps like Zoom, Teams and Chrome change the microphone level on their own.")
                    }
                    if model.lockLevel {
                        LabeledContent("Level") {
                            HStack {
                                Slider(value: Binding(get: { model.lockedLevel ?? model.inputLevel ?? 0.5 },
                                                      set: { model.setLockedLevel($0) }), in: 0...1) {
                                    Text("Level")
                                } minimumValueLabel: {
                                    Image(systemName: "mic").foregroundStyle(.secondary)
                                } maximumValueLabel: {
                                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                                }
                                .labelsHidden()
                                .disabled(model.inputLevel == nil)
                                Text(percent(model.lockedLevel ?? model.inputLevel ?? 0)).monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .disabled(!model.isEnabled)
            .opacity(model.isEnabled ? 1 : 0.45)

            Section("Now") {
                LabeledContent("Input", value: model.inputName)
                LabeledContent("Level", value: model.inputLevel.map(percent) ?? "No level control")
                LabeledContent("Kept AirPods off the mic") { countView(model.hiFiCount, model.hiFiLast) }
                if model.iPhoneCount > 0 {
                    LabeledContent("Kept iPhone off the mic") { countView(model.iPhoneCount, model.iPhoneLast) }
                }
                if model.lockLevel || model.levelCount > 0 {
                    LabeledContent("Restored the mic level") { countView(model.levelCount, model.levelLast) }
                }
            }
            Section("Updates") {
                Toggle(isOn: Binding(get: { model.automaticUpdates }, set: { model.setAutomaticUpdates($0) })) {
                    Text("Install updates automatically")
                    Text("Only updates signed by the developer and notarized by Apple.")
                }
                HStack {
                    Text("Version \(model.version), \(model.lastCheckedText.lowercased().replacingOccurrences(of: "checked:", with: "checked"))")
                        .lineLimit(1)
                    Spacer()
                    Button(model.checkingUpdates ? "Checking..." : "Check Now") { model.checkUpdates() }
                        .disabled(model.checkingUpdates)
                }
                if !model.automaticUpdates, let version = model.availableVersion {
                    Button("Install \(version)") { model.checkUpdates(install: true) }
                        .disabled(model.checkingUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .alert("MicKeeper", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Computed when the window opens and then once a minute, not on every redraw. One timeline per row, so each
    /// stays its own row in the form (with a separator).
    private func countView(_ count: Int, _ last: Date?) -> some View {
        TimelineView(.everyMinute) { context in
            Text(countText(count, last, now: context.date)).foregroundStyle(.secondary)
        }
    }

    private func countText(_ count: Int, _ last: Date?, now: Date) -> String {
        guard count > 0 else { return "Not yet" }
        let times = count == 1 ? "Once" : "\(count) times"
        guard let last else { return times }
        return "\(times), last \(timeAgo(last, now: now))"
    }

    @ViewBuilder private var statusRow: some View {
        switch model.agentStatus {
        case .enabled:
            StatusRow(symbol: "checkmark.circle.fill", color: .green, title: "MicKeeper Is On",
                      detail: Audio.isHeadset(model.input) && model.preferredUID == nil
                          ? "Your headphones are the microphone: no other microphone is available."
                          : "Using \(model.inputName) as the microphone.")
        case .requiresApproval:
            StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                      title: "Approval Required",
                      detail: "Allow MicKeeper under \u{201C}Allow in the Background\u{201D} so it can run without this window.",
                      action: ("Open Login Items\u{2026}", { SMAppService.openSystemSettingsLoginItems() }))
        default:
            StatusRow(symbol: "circle", color: .secondary, title: "MicKeeper Is Off",
                      detail: "macOS picks the microphone and apps change its level, as usual.")
        }
    }
}

/// A status line in the style of System Settings: symbol, title, explanation and an optional button.
struct StatusRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.label, action: action.run).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Login items

// Remove the updater first, since removing the main job can terminate the background process.
func setLoginItemsEnabled(_ enabled: Bool) throws {
    let names = enabled ? [agentPlistName, updaterPlistName] : [updaterPlistName, agentPlistName]
    var firstError: Error?
    for name in names {
        let service = SMAppService.agent(plistName: name)
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            if firstError == nil { firstError = error }
        }
    }
    if let firstError { throw firstError }
}

@discardableResult
func launchctl(_ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Starts the agent once through launchd. After an update this makes launchd pin the agent to the new build;
/// without it the job can stay stuck with "needs LWCR update" (see scripts/install.sh).
func startAgentOnce() { launchctl(["kickstart", agentJob]) }

func agentIsRunning() -> Bool { launchctl(["print", agentJob]).contains("state = running") }

/// Unregister, wait until launchd has dropped the job, register and start once: the sequence that refreshes
/// the agent's launch constraint after an update (see scripts/install.sh).
func reregisterAgent() {
    try? setLoginItemsEnabled(false)
    for job in [updaterJob, agentJob] {
        for _ in 0..<70 where !launchctl(["print", job]).isEmpty { Thread.sleep(forTimeInterval: 0.5) }
    }
    Thread.sleep(forTimeInterval: 1)
    try? setLoginItemsEnabled(true)
    startAgentOnce()
    Thread.sleep(forTimeInterval: 2)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `MicKeeper --unregister` / `--register` (used by the Makefile): change the login item and quit.
        if CommandLine.arguments.contains("--unregister") {
            try? setLoginItemsEnabled(false)
            exit(0)
        }
        if CommandLine.arguments.contains("--register") {
            do {
                try setLoginItemsEnabled(true)
                startAgentOnce()
                // This build is registered now; the window must not re-register it again (see reregisterAfterUpdate).
                UserDefaults.standard.set(currentBuildID, forKey: registeredBuildKey)
                UserDefaults.standard.synchronize()  // exit() would otherwise drop the unsaved value
                exit(0)
            } catch {
                FileHandle.standardError.write("MicKeeper: could not register the background agent: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !NOTIFICATION_TESTS
@main
#endif
enum MicKeeperMain {
    @MainActor
    static func main() {
        // Inspect notification arguments before creating NSApplication, a delegate or any SwiftUI state.
        if CommandLine.arguments.contains("--notify-update") {
            exit(notifyUpdate(CommandLine.arguments))
        }
        MicKeeperApp.main()
    }
}

struct MicKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("MicKeeper", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
