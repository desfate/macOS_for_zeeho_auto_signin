import AppKit
import Combine
import Foundation
import SwiftUI

private let statusURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ZeehoSignin/status.json")

private enum ZeehoIcon {
    static func png(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    static var menu: NSImage {
        let img = png("zeeho-menu") ?? NSImage(size: NSSize(width: 18, height: 18))
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }

    static var mark: NSImage {
        png("zeeho-mark") ?? menu
    }
}

struct VehicleStatus: Codable, Equatable {
    var vehicleName: String?
    var vehiclePicUrl: String?
    var battery: Int?
    var rangeKm: Int?
    var mileageKm: Double?
    var lockText: String?
    var chargeText: String?
    var rideState: String?
    var signal: String?
    var locationTime: String?
}

struct SigninStatus: Codable, Equatable {
    var ok: Bool?
    var title: String?
    var message: String?
    var error: String?
    var today: String?
    var userId: String?
    var nickName: String?
    var avatar: String?
    var signedToday: Bool?
    var lastTime: String?
    var continueDays: Int?
    var integral: Int?
    var totalIntegral: Int?
    var tokenInvalid: Bool?
    var posted: Bool?
    var phone: String?
    var vehicle: VehicleStatus?
    var updatedAt: String?
}

private struct CommandResult: Decodable {
    var ok: Bool
    var message: String
}

@MainActor
final class StatusStore: ObservableObject {
    @Published var status = SigninStatus()
    @Published var refreshing = false
    @Published var lastError = ""
    @Published var notice = ""
    @Published var updatingToken = false

    var needsToken: Bool { status.tokenInvalid == true }

    private var timer: AnyCancellable?
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    init() {
        reload()
        watchFile()
        refreshFromNetwork()
        timer = Timer.publish(every: 5 * 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollNetwork() }
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: statusURL.path) else {
            lastError = "还没有状态文件，先刷新一次"
            return
        }
        do {
            let data = try Data(contentsOf: statusURL)
            status = try JSONDecoder().decode(SigninStatus.self, from: data)
            if status.tokenInvalid == true {
                lastError = status.message ?? "Token 失效，请从 App 抓包后粘贴 Authorization"
            } else {
                lastError = status.error ?? ""
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshFromNetwork() {
        runPython(["--status-only"])
    }

    private func pollNetwork() {
        guard !refreshing, !updatingToken else { return }
        guard status.tokenInvalid != true else { return }
        refreshFromNetwork()
    }

    func updateToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            lastError = "Token 为空"
            return
        }
        updatingToken = true
        runPython(["--set-token", token], updating: true, alert: true)
    }

    private func runPython(_ arguments: [String], updating: Bool = false, alert: Bool = false) {
        if refreshing {
            if updating || alert {
                lastError = "正在处理上一个请求，请稍后再试"
                updatingToken = false
            }
            return
        }
        refreshing = true
        lastError = ""
        notice = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ZeehoPaths.pythonBin)
            proc.arguments = [ZeehoPaths.pythonScript] + arguments
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            let stdout = NSMutableData()
            let stderr = NSMutableData()
            out.fileHandleForReading.readabilityHandler = { handle in
                stdout.append(handle.availableData)
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                stderr.append(handle.availableData)
            }
            do {
                try proc.run()
                proc.waitUntilExit()
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                stdout.append(out.fileHandleForReading.readDataToEndOfFile())
                stderr.append(err.fileHandleForReading.readDataToEndOfFile())
                let outText = String(data: stdout as Data, encoding: .utf8) ?? ""
                let errText = String(data: stderr as Data, encoding: .utf8) ?? ""
                let status = proc.terminationStatus
                DispatchQueue.main.async {
                    self.refreshing = false
                    self.updatingToken = false
                    let parsed = Self.parseResult(outText) ?? Self.parseResult(errText)
                    if let parsed {
                        self.applyCommandOutcome(ok: parsed.ok, message: parsed.message, alert: alert)
                        self.reload()
                        self.applyCommandOutcome(ok: parsed.ok, message: parsed.message, alert: false)
                        if parsed.ok, updating {
                            self.refreshFromNetwork()
                        }
                    } else if status != 0 {
                        let message = errText.isEmpty ? "失败 \(status)" : errText
                        self.applyCommandOutcome(ok: false, message: message, alert: alert)
                    } else if alert {
                        self.applyCommandOutcome(ok: false, message: "没有返回结果，请重试", alert: true)
                    } else {
                        self.reload()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.refreshing = false
                    self.updatingToken = false
                    self.applyCommandOutcome(ok: false, message: error.localizedDescription, alert: alert)
                }
            }
        }
    }

    private static func parseResult(_ text: String) -> CommandResult? {
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.hasPrefix("RESULT ") ? String(line.dropFirst(7)) : nil
            guard let raw, let data = raw.data(using: .utf8) else { continue }
            if let parsed = try? JSONDecoder().decode(CommandResult.self, from: data) {
                return parsed
            }
        }
        return nil
    }

    private func applyCommandOutcome(ok: Bool, message: String, alert: Bool) {
        if ok {
            notice = message
            lastError = ""
        } else {
            notice = ""
            lastError = message
        }
        guard alert else { return }
        NSApp.activate(ignoringOtherApps: true)
        let sheet = NSAlert()
        sheet.messageText = ok ? "成功" : "失败"
        sheet.informativeText = message
        sheet.alertStyle = ok ? .informational : .warning
        sheet.addButton(withTitle: "好")
        sheet.runModal()
    }

    private func watchFile() {
        let dir = statusURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.reload() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        src.resume()
        source = src
    }
}

/// Material 3 深色方案（钢蓝种子色）：分层 surface，不是一片黑。
private struct M3 {
    var primary: Color { Color(hex: 0xA9C7FF) }
    var onPrimary: Color { Color(hex: 0x00315C) }
    var primaryContainer: Color { Color(hex: 0x2A4A73) }
    var onPrimaryContainer: Color { Color(hex: 0xD6E3FF) }

    var secondaryContainer: Color { Color(hex: 0x3E4759) }
    var onSecondaryContainer: Color { Color(hex: 0xDCE2F5) }

    var tertiaryContainer: Color { Color(hex: 0x5C4033) }
    var onTertiaryContainer: Color { Color(hex: 0xFFDBCD) }

    var error: Color { Color(hex: 0xFFB4AB) }
    var onError: Color { Color(hex: 0x690005) }
    var errorContainer: Color { Color(hex: 0x93000A) }
    var onErrorContainer: Color { Color(hex: 0xFFDAD6) }

    var surface: Color { Color(hex: 0x111318) }
    var surfaceContainer: Color { Color(hex: 0x1D2024) }
    var surfaceContainerHigh: Color { Color(hex: 0x282A2E) }
    var surfaceContainerHighest: Color { Color(hex: 0x333538) }
    var onSurface: Color { Color(hex: 0xE2E2E6) }
    var onSurfaceVariant: Color { Color(hex: 0xC3C6CF) }
    var outline: Color { Color(hex: 0x8D9199) }
    var outlineVariant: Color { Color(hex: 0x43474E) }

    var extraLarge: CGFloat { 28 }
    var large: CGFloat { 16 }
    var medium: CGFloat { 12 }
}

private enum M3Type {
    static let labelSmall = Font.system(size: 11, weight: .medium)
    static let labelMedium = Font.system(size: 12, weight: .medium)
    static let labelLarge = Font.system(size: 14, weight: .medium)
    static let titleMedium = Font.system(size: 16, weight: .medium)
    static let headlineSmall = Font.system(size: 24, weight: .regular)
    static let displaySmall = Font.system(size: 36, weight: .regular)
    static let bodyMedium = Font.system(size: 14, weight: .regular)
    static let bodySmall = Font.system(size: 12, weight: .regular)
}

private struct M3TonalButtonStyle: ButtonStyle {
    var m3: M3
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(M3Type.labelLarge)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(m3.primaryContainer, in: Capsule())
            .foregroundStyle(m3.onPrimaryContainer)
            .opacity(disabled ? 0.38 : (configuration.isPressed ? 0.88 : 1))
    }
}

private struct DarkTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var textColor: NSColor
    var placeholderColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = context.coordinator
        applyStyle(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        applyStyle(field)
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    private func applyStyle(_ field: NSTextField) {
        field.appearance = NSAppearance(named: .darkAqua)
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: NSFont.systemFont(ofSize: 14),
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            text.wrappedValue = (obj.object as? NSTextField)?.stringValue ?? ""
        }
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct SigninCard: View {
    @ObservedObject var store: StatusStore
    var compact: Bool = false
    var onShowDesktop: (() -> Void)? = nil
    var onQuit: (() -> Void)? = nil
    @State private var editingToken = false
    @State private var tokenDraft = ""

    private var m3: M3 { M3() }
    private var signed: Bool { store.status.signedToday == true }
    private var tokenInvalid: Bool { store.needsToken }

    private var title: String {
        if tokenInvalid { return "Token 失效" }
        if store.status.ok == false { return "状态异常" }
        return signed ? "今日已签到" : "今日未签到"
    }

    private var chipLabel: String {
        if tokenInvalid { return "需更新 Token" }
        return signed ? "已签到" : "未签到"
    }

    private var chipColors: (Color, Color) {
        if tokenInvalid { return (m3.errorContainer, m3.onErrorContainer) }
        if signed { return (m3.primaryContainer, m3.onPrimaryContainer) }
        return (m3.tertiaryContainer, m3.onTertiaryContainer)
    }

    private var totalPoints: String {
        (store.status.totalIntegral ?? store.status.integral).map { "\($0)" } ?? "—"
    }

    private var lastTimeShort: String {
        guard let t = store.status.lastTime, !t.isEmpty else { return "—" }
        let parts = t.split(separator: " ")
        if parts.count >= 2 { return String(parts[1].prefix(5)) }
        return t
    }

    private var updatedAtShort: String {
        guard let t = store.status.updatedAt, t.count >= 16 else { return store.status.updatedAt ?? "" }
        // 2026-09-15 16:54:13 → 09-15 16:54
        let monthDay = t.dropFirst(5).prefix(5)
        let hm = t.dropFirst(11).prefix(5)
        return "\(monthDay) \(hm)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header
            identity
            heroMetric
            HStack(spacing: 8) {
                sideMetric(label: "连签", value: "\(store.status.continueDays ?? 0) 天")
                sideMetric(label: "上次", value: lastTimeShort)
            }
            if store.status.vehicle != nil {
                vehicleSection
            }
            if tokenInvalid || editingToken {
                tokenEditor
            }
            if !store.notice.isEmpty {
                Text(store.notice)
                    .font(M3Type.bodySmall)
                    .foregroundStyle(m3.onPrimaryContainer)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(m3.primaryContainer, in: RoundedRectangle(cornerRadius: m3.medium, style: .continuous))
            }
            if !store.lastError.isEmpty {
                errorBanner
            }
            footer
            if compact {
                compactActions
            }
        }
        .padding(compact ? 14 : 20)
        .frame(width: compact ? 300 : 340, alignment: .leading)
        .background(m3.surface, in: RoundedRectangle(cornerRadius: m3.extraLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: m3.extraLarge, style: .continuous)
                .strokeBorder(m3.outlineVariant.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, y: 8)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: ZeehoIcon.mark)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("ZEEHO")
                .font(M3Type.labelSmall)
                .tracking(1.6)
                .foregroundStyle(m3.onSurfaceVariant)
            Spacer()
            let colors = chipColors
            Text(chipLabel)
                .font(M3Type.labelMedium)
                .foregroundStyle(colors.1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(colors.0, in: Capsule())
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(compact ? M3Type.titleMedium : M3Type.headlineSmall)
                    .foregroundStyle(m3.onSurface)
                    .lineLimit(1)
                if let name = store.status.nickName, !name.isEmpty {
                    Text(name)
                        .font(M3Type.bodyMedium)
                        .foregroundStyle(m3.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        let size: CGFloat = compact ? 36 : 40
        Group {
            if let raw = store.status.avatar, let url = URL(string: raw), !raw.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(m3.secondaryContainer)
            Image(systemName: "person.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(m3.onSecondaryContainer)
        }
    }

    private var heroMetric: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("总积分")
                .font(M3Type.labelMedium)
                .foregroundStyle(m3.onPrimaryContainer.opacity(0.82))
            Text(totalPoints)
                .font(M3Type.displaySmall)
                .monospacedDigit()
                .foregroundStyle(m3.onPrimaryContainer)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 14 : 18)
        .background(m3.primaryContainer, in: RoundedRectangle(cornerRadius: m3.large, style: .continuous))
    }

    private func sideMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(M3Type.labelMedium)
                .foregroundStyle(m3.onSurfaceVariant)
            Text(value)
                .font(M3Type.titleMedium)
                .monospacedDigit()
                .foregroundStyle(m3.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 10 : 12)
        .background(m3.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: m3.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: m3.medium, style: .continuous)
                .strokeBorder(m3.outlineVariant.opacity(0.35), lineWidth: 1)
        )
    }

    private var vehicle: VehicleStatus { store.status.vehicle ?? VehicleStatus() }

    private var mileageText: String {
        guard let n = vehicle.mileageKm else { return "—" }
        return "\(Int(n.rounded())) km"
    }

    private var locationTimeText: String {
        (vehicle.locationTime ?? "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private var vehicleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                vehicleThumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(vehicle.vehicleName?.isEmpty == false ? vehicle.vehicleName! : "车辆")
                        .font(M3Type.titleMedium)
                        .foregroundStyle(m3.onSurface)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let state = vehicle.rideState, !state.isEmpty {
                            Text(state)
                        }
                        if !locationTimeText.isEmpty {
                            Text(locationTimeText)
                        }
                    }
                    .font(M3Type.bodySmall)
                    .foregroundStyle(m3.onSurfaceVariant)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                sideMetric(label: "电量", value: vehicle.battery.map { "\($0)%" } ?? "—")
                sideMetric(label: "续航", value: vehicle.rangeKm.map { "\($0) km" } ?? "—")
            }
            sideMetric(label: "总里程", value: mileageText)
            if !compact {
                HStack(spacing: 8) {
                    sideMetric(label: "车锁", value: vehicle.lockText ?? "—")
                    sideMetric(label: "充电", value: vehicle.chargeText ?? "—")
                    sideMetric(label: "信号", value: vehicle.signal ?? "—")
                }
            }
        }
        .padding(10)
        .background(m3.surfaceContainer, in: RoundedRectangle(cornerRadius: m3.large, style: .continuous))
    }

    @ViewBuilder
    private var vehicleThumb: some View {
        let size: CGFloat = compact ? 36 : 44
        Group {
            if let raw = vehicle.vehiclePicUrl, let url = URL(string: raw), !raw.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "bicycle")
                            .foregroundStyle(m3.onSurfaceVariant)
                    }
                }
            } else {
                Image(systemName: "bicycle")
                    .foregroundStyle(m3.onSurfaceVariant)
            }
        }
        .frame(width: size, height: size)
        .padding(6)
        .background(m3.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var tokenEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("从 App 抓包复制 Authorization，或签到页 URL 里的 token=")
                .font(M3Type.bodySmall)
                .foregroundStyle(m3.onSurfaceVariant)
            fieldBox("Bearer Token / 抓包 URL", text: $tokenDraft)
            HStack {
                Button("粘贴") {
                    tokenDraft = NSPasteboard.general.string(forType: .string) ?? tokenDraft
                }
                Spacer()
                Button(store.updatingToken ? "保存中" : "保存") {
                    store.updateToken(tokenDraft)
                }
                .disabled(store.updatingToken || store.refreshing)
            }
            .buttonStyle(.plain)
            .font(M3Type.labelLarge)
            .foregroundStyle(m3.primary)

            if !tokenInvalid {
                Button("取消") {
                    editingToken = false
                    tokenDraft = ""
                }
                .buttonStyle(.plain)
                .font(M3Type.labelLarge)
                .foregroundStyle(m3.onSurfaceVariant)
            }
        }
        .onChange(of: store.status.tokenInvalid) { _, invalid in
            if invalid != true {
                tokenDraft = ""
                editingToken = false
            }
        }
    }

    private func fieldBox(_ placeholder: String, text: Binding<String>) -> some View {
        DarkTextField(
            placeholder: placeholder,
            text: text,
            textColor: NSColor(m3.onSurface),
            placeholderColor: NSColor(m3.onSurfaceVariant)
        )
        .frame(minHeight: 18)
        .padding(10)
        .background(m3.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: m3.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: m3.medium, style: .continuous)
                .strokeBorder(m3.outlineVariant, lineWidth: 1)
        )
    }

    private var errorBanner: some View {
        Text(store.lastError)
            .font(M3Type.bodySmall)
            .foregroundStyle(m3.onErrorContainer)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(m3.errorContainer, in: RoundedRectangle(cornerRadius: m3.medium, style: .continuous))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(updatedAtShort)
                .font(M3Type.labelSmall)
                .foregroundStyle(m3.outline)
            Spacer()
            if !tokenInvalid, !editingToken {
                Button("更新 Token") {
                    editingToken = true
                }
                .buttonStyle(.plain)
                .font(M3Type.labelLarge)
                .foregroundStyle(m3.primary)
            }
            Button {
                store.refreshFromNetwork()
            } label: {
                HStack(spacing: 6) {
                    if store.refreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(m3.onPrimaryContainer)
                    }
                    Text(store.refreshing ? "刷新中" : "刷新")
                }
            }
            .buttonStyle(M3TonalButtonStyle(m3: m3, disabled: store.refreshing))
            .disabled(store.refreshing)
        }
    }

    private var compactActions: some View {
        HStack(spacing: 8) {
            Button("桌面卡片") { onShowDesktop?() }
            Button("退出") { onQuit?() }
            Spacer()
        }
        .buttonStyle(.plain)
        .font(M3Type.labelLarge)
        .foregroundStyle(m3.primary)
        .padding(.top, 4)
    }
}

@main
struct ZeehoSigninApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = StatusStore()

    var body: some Scene {
        MenuBarExtra {
            SigninCard(
                store: store,
                compact: true,
                onShowDesktop: { AppDelegate.showDesktopCard() },
                onQuit: { NSApp.terminate(nil) }
            )
            .padding(8)
        } label: {
            Image(nsImage: ZeehoIcon.menu)
        }
        .menuBarExtraStyle(.window)

        Window("极核签到", id: "desktop-card") {
            SigninCard(store: store)
                .padding(12)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .defaultSize(width: 364, height: 520)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(fileURLWithPath: "/dev/null")) {
            NSApp.applicationIconImage = icon
        } else if let mark = ZeehoIcon.png("zeeho-mark") {
            NSApp.applicationIconImage = mark
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AppDelegate.showDesktopCard()
        }
    }

    static func showDesktopCard() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.identifier?.rawValue == "desktop-card" || $0.title == "极核签到" })?
            .makeKeyAndOrderFront(nil)
        for window in NSApp.windows where window.title == "极核签到" {
            window.identifier = NSUserInterfaceItemIdentifier("desktop-card")
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("desktop-card")
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.setIsVisible(true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
