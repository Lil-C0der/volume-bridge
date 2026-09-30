import SwiftUI
import AppKit
import Foundation

// Explicit language is also passed to the short-lived administrator process.
// Only supported language codes are accepted; raw system/driver diagnostics stay intact.
enum AppLanguage {
    static let supported = ["zh-Hans", "en", "ja"]
    static var selected: String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--language"), index + 1 < args.count,
           supported.contains(args[index + 1]) { return args[index + 1] }
        return UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    }
    static var code: String {
        resolve(selected, preferred: Locale.preferredLanguages)
    }
    static func resolve(_ selected: String, preferred: [String]) -> String {
        if supported.contains(selected) { return selected }
        for language in preferred {
            if language.hasPrefix("zh-Hans") || language == "zh" || language.hasPrefix("zh-CN") || language.hasPrefix("zh-SG") { return "zh-Hans" }
            if language.hasPrefix("en") { return "en" }
            if language.hasPrefix("ja") { return "ja" }
        }
        return "en"
    }
    static func text(_ key: String, code: String) -> String {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
func L(_ key: String, _ args: CVarArg...) -> String {
    let code = AppLanguage.code
    return String(format: AppLanguage.text(key, code: code), locale: Locale(identifier: code), arguments: args)
}

struct CommandResult { let code: Int32; let data: Data; var text: String { String(decoding: data, as: UTF8.self) } }
func run(_ path: String, _ args: [String]) throws -> CommandResult {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = pipe; p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return CommandResult(code: p.terminationStatus, data: data)
}
struct DeskError: LocalizedError { let message: String; var errorDescription: String? { message } }
func checked(_ path: String, _ args: [String]) throws -> CommandResult {
    let r = try run(path, args)
    guard r.code == 0 else { throw DeskError(message: r.text) }
    return r
}
func info(_ id: String) throws -> [String: Any] {
    let r = try checked("/usr/sbin/diskutil", ["info", "-plist", id])
    return try PropertyListSerialization.propertyList(from: r.data, format: nil) as? [String: Any] ?? [:]
}
func validID(_ s: String) -> Bool { s.range(of: "^disk[0-9]+s[0-9]+$", options: .regularExpression) != nil }
func mountPath(_ id: String) -> String { "/Volumes/NTFSDesk-\(id)" }
func hasMount(_ path: String) -> Bool {
    let output = (try? run("/sbin/mount", []).text) ?? ""
    var physical = path
    if let resolved = realpath(path, nil) {
        physical = String(cString: resolved)
        free(resolved)
    }
    return output.contains(" on \(physical) (") || output.contains(" on \(path) (")
}
func ownedMount(_ id: String) -> Bool { hasMount(mountPath(id)) }
func waitMount(_ path: String) throws {
    for _ in 0..<150 {
        if hasMount(path) { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw DeskError(message: L("驱动返回后未检测到挂载点。"))
}
func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
func backend() -> String { Bundle.main.resourceURL!.appendingPathComponent("driver/sbin/ntfs-3g").path }
func runtimeReady() -> Bool {
    FileManager.default.isExecutableFile(atPath: backend()) &&
    FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/fuse_t.framework/Resources/go-nfsv4").path)
}
func diskAccessHint(_ device: String) -> String { L("disk.access.hint", device) }

func checkRawReadAccess(_ device: String) throws {
    // Opening and closing the raw device performs no disk writes. The caller
    // checks after normal unmount and restores read-only access on failure.
    let fd = Darwin.open(device, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else {
        let code = errno
        if code == EPERM || code == EACCES { throw DeskError(message: diskAccessHint(device)) }
        if code == EBUSY {
            throw DeskError(message: L("磁盘正常卸载后仍被占用。请关闭使用该磁盘的文件、复制任务和其他磁盘管理工具，再重试。"))
        }
        throw DeskError(message: L("disk.open.failed", String(cString: strerror(code))))
    }
    Darwin.close(fd)
}
func driverFailure(_ text: String, device: String) -> String {
    if text.contains("Error opening") && (text.contains("Operation not permitted") || text.contains("Permission denied")) {
        return diskAccessHint(device)
    }
    return text
}
func nativeMountPath(_ d: [String: Any]) -> String? {
    guard let path = d["MountPoint"] as? String, !path.isEmpty else { return nil }
    return path
}
func verifiedInfo(_ id: String, _ uuid: String) throws -> [String: Any] {
    let d = try info(id)
    guard d["Internal"] as? Bool == false,
          (d["FilesystemType"] as? String)?.lowercased() == "ntfs",
          d["VolumeUUID"] as? String == uuid else {
        throw DeskError(message: L("磁盘身份或文件系统已变化，请刷新后重试。"))
    }
    return d
}
func unmountNativeIfMounted(_ id: String, _ uuid: String) throws {
    let latest = try verifiedInfo(id, uuid)
    guard let path = nativeMountPath(latest), hasMount(path) else { return }
    let result = try run("/usr/sbin/diskutil", ["unmount", id])
    if result.code != 0 {
        // Another disk-management event can complete the unmount concurrently.
        // Only the verified desired state makes a failed command acceptable.
        let after = try verifiedInfo(id, uuid)
        if let remaining = nativeMountPath(after), hasMount(remaining) {
            throw DeskError(message: result.text)
        }
    }
}

// This short-lived privileged mode accepts only an external NTFS partition with
// the UUID observed by the UI. It provides no arbitrary command execution API.
func helper(_ args: [String]) throws {
    guard geteuid() == 0, args.count == 5 else { throw DeskError(message: L("挂载操作需要系统管理员授权。")) }
    let action = args[0], id = args[1], uuid = args[2]
    guard validID(id), ["rw", "ro", "eject"].contains(action),
          let uid = UInt32(args[3]), uid >= 501, let gid = UInt32(args[4]) else {
        throw DeskError(message: L("操作参数无效。"))
    }
    let d = try verifiedInfo(id, uuid)
    let target = mountPath(id)
    if action == "rw" {
        guard runtimeReady() else {
            throw DeskError(message: L("应用内的读写组件缺失，请重新构建应用。"))
        }
    }
    if ownedMount(id) { _ = try checked("/sbin/umount", [target]) }
    if action == "eject" {
        _ = try checked("/usr/sbin/diskutil", ["eject", d["ParentWholeDisk"] as? String ?? id]); return
    }
    if action == "ro" {
        try unmountNativeIfMounted(id, uuid)
        _ = try checked("/usr/sbin/diskutil", ["mount", "readOnly", id])
        let mounted = try verifiedInfo(id, uuid)
        guard let path = nativeMountPath(mounted), hasMount(path), mounted["WritableVolume"] as? Bool == false else {
            throw DeskError(message: L("只读挂载完成后，系统状态验证失败。"))
        }
        print(L("mounted.ro", path))
        return
    }
    try unmountNativeIfMounted(id, uuid)
    do {
        // macOS can return EBUSY when its native filesystem owns the mounted
        // device. Raw access is checked only after a successful normal unmount.
        try checkRawReadAccess("/dev/" + id)
        let current = try info(id)
        guard current["Internal"] as? Bool == false,
              (current["FilesystemType"] as? String)?.lowercased() == "ntfs",
              current["VolumeUUID"] as? String == uuid else {
            throw DeskError(message: L("卸载后磁盘身份已变化，请刷新后重试。"))
        }
        if FileManager.default.fileExists(atPath: target) {
            let a = try FileManager.default.attributesOfItem(atPath: target)
            guard a[.type] as? FileAttributeType == .typeDirectory,
                  (a[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  try FileManager.default.contentsOfDirectory(atPath: target).isEmpty else {
                throw DeskError(message: L("挂载目录被占用。"))
            }
        } else { try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
        let options = "rw,norecover,windows_names,uid=\(uid),gid=\(gid),umask=022,noatime,volname=NTFSDesk-\(id)"
        let mounted = try run(backend(), ["/dev/" + id, target, "-o", options])
        guard mounted.code == 0 else { throw DeskError(message: driverFailure(mounted.text, device: "/dev/" + id)) }
        // FUSE-T completes its macOS mount asynchronously after the driver exits.
        try waitMount(target)
        print(L("mounted.rw", target))
    } catch {
        // Restore a native read-only mount after a rejected write mount.
        if ownedMount(id) { _ = try? checked("/sbin/umount", [target]) }
        if let restored = try? info(id), restored["VolumeUUID"] as? String == uuid {
            _ = try? checked("/usr/sbin/diskutil", ["mount", "readOnly", id])
        }
        throw error
    }
}

func selfTest() throws -> String {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("VolumeBridge-Test-" + UUID().uuidString)
    let image = root.appendingPathComponent("test.img"), target = root.appendingPathComponent("mount")
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    defer {
        if hasMount(target.path) { _ = try? checked("/sbin/umount", [target.path]) }
        if !hasMount(target.path) { try? fm.removeItem(at: root) }
    }
    fm.createFile(atPath: image.path, contents: nil)
    let file = try FileHandle(forWritingTo: image)
    try file.truncate(atOffset: 64 * 1024 * 1024); try file.close()
    let formatter = Bundle.main.resourceURL!.appendingPathComponent("driver/sbin/mkntfs").path
    _ = try checked(formatter, ["-F", "-Q", "-s", "512", "-c", "4096", "-L", "VolumeBridge-Test", image.path])
    func mount(_ mode: String) throws {
        _ = try checked(backend(), [image.path, target.path, "-o", "\(mode),norecover,windows_names,volname=VolumeBridge-Test"])
        try waitMount(target.path)
    }
    try mount("rw")
    let folder = target.appendingPathComponent("中文 文件夹")
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
    let original = folder.appendingPathComponent("测试.bin"), renamed = folder.appendingPathComponent("重命名.bin")
    try payload.write(to: original)
    try fm.moveItem(at: original, to: renamed)
    let deleted = target.appendingPathComponent("delete-me")
    try Data("delete".utf8).write(to: deleted); try fm.removeItem(at: deleted)
    _ = try checked("/sbin/umount", [target.path])
    try mount("ro")
    guard try Data(contentsOf: renamed) == payload, !fm.fileExists(atPath: deleted.path) else {
        throw DeskError(message: L("重新挂载后数据验证失败。"))
    }
    var rejected = false
    do { try Data("x".utf8).write(to: target.appendingPathComponent("readonly-check")) }
    catch { rejected = true }
    guard rejected else { throw DeskError(message: L("只读写入保护验证失败。")) }
    _ = try checked("/sbin/umount", [target.path])
    return L("自检通过：中文文件名、1 MB 写入、重命名、删除、重新挂载后数据一致性、只读保护。")
}

struct Usage {
    let total: Int64, available: Int64
    var used: Int64 { total - available }
    var fraction: Double { Double(used) / Double(total) }
}
func diskUsage(_ path: String) -> Usage? {
    guard !path.isEmpty,
          let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
          let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
          let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
          total > 0, free >= 0, free <= total else { return nil }
    return Usage(total: total, available: free)
}
func capacityText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
}
struct Volume: Identifiable {
    let id: String, name: String, uuid: String, fs: String, path: String
    let size: Int64, writable: Bool
    let usage: Usage?
    var ntfs: Bool { fs.lowercased() == "ntfs" }
}
func volumes() throws -> [Volume] {
    let r = try checked("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
    let list = try PropertyListSerialization.propertyList(from: r.data, format: nil) as? [String: Any] ?? [:]
    var result: [Volume] = []
    for disk in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
        for part in disk["Partitions"] as? [[String: Any]] ?? [] {
            guard let id = part["DeviceIdentifier"] as? String, validID(id), let d = try? info(id),
                  let fs = d["FilesystemType"] as? String else { continue }
            let own = ownedMount(id)
            let path = own ? mountPath(id) : d["MountPoint"] as? String ?? ""
            let usage = diskUsage(path)
            let candidates = ["VolumeSize", "TotalSize", "Size"].compactMap { (d[$0] as? NSNumber)?.int64Value }.filter { $0 > 0 }
            result.append(Volume(id: id, name: d["VolumeName"] as? String ?? id,
                uuid: d["VolumeUUID"] as? String ?? "", fs: fs,
                path: path,
                size: usage?.total ?? candidates.first ?? 0,
                writable: own || d["WritableVolume"] as? Bool == true,
                usage: usage))
        }
    }
    return result.sorted { lhs, rhs in
        if lhs.ntfs != rhs.ntfs { return lhs.ntfs }
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}
@MainActor final class Model: ObservableObject {
    @Published var disks: [Volume] = []
    @Published var busy = false
    @Published var message = L("正在扫描外接磁盘…")
    @Published var error: String?
    var ready: Bool { runtimeReady() }
    func refresh() {
        guard !busy else { return }; busy = true
        Task {
            let r = await Task.detached { Result { try volumes() } }.value
            switch r { case .success(let v): disks = v; message = L(v.filter { $0.ntfs }.count == 1 ? "ntfs.count.one" : "ntfs.count", v.filter { $0.ntfs }.count); case .failure(let e): error = e.localizedDescription }
            busy = false
        }
    }
    func act(_ action: String, _ volume: Volume) {
        guard !busy else { return }; busy = true; message = L("processing", volume.name)
        let exe = Bundle.main.executableURL!.path
        let command = ([exe, "--helper", action, volume.id, volume.uuid, String(getuid()), String(getgid()), "--language", AppLanguage.code]).map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleQuote(command)) with administrator privileges"
        Task {
            let r = await Task.detached { Result { try checked("/usr/bin/osascript", ["-e", script]).text } }.value
            switch r { case .success(let text): message = text.trimmingCharacters(in: .whitespacesAndNewlines); case .failure(let e): error = e.localizedDescription; message = L("操作已结束") }
            busy = false; refresh()
        }
    }
    func test() {
        guard !busy else { return }; busy = true; message = L("正在独立的 64 MB 镜像中验证读写…")
        Task {
            let r = await Task.detached { Result { try selfTest() } }.value
            switch r { case .success(let text): message = text; case .failure(let e): error = e.localizedDescription; message = L("自检结束，请查看提示") }
            busy = false
        }
    }
}
struct ContentView: View {
    @StateObject var model = Model()
    @State private var detail: Volume?
    @State private var showLanguageSettings = false
    @AppStorage("appLanguage") private var language = "system"
    let timer = Timer.publish(every: 12, on: .main, in: .common).autoconnect()
    private let gap: CGFloat = 12
    private let formatWidth: CGFloat = 62
    private let statusWidth: CGFloat = 96
    private let usageWidth: CGFloat = 174
    private var textButtonWidth: CGFloat { AppLanguage.code == "en" ? 92 : AppLanguage.code == "ja" ? 100 : 60 }
    private var actionWidth: CGFloat { textButtonWidth * 2 + 88 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").foregroundStyle(.blue)
                Text(L("磁盘")).font(.title3.bold())
                Text(L(model.disks.count == 1 ? "external.count.one" : "external.count", model.disks.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(L("语言") + "…") { showLanguageSettings = true }
                    Divider()
                    Button(L("验证读写")) { model.test() }.disabled(!model.ready || model.busy)
                    Button(L("磁盘访问权限…")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize().help(L("设置与验证"))
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.busy).help(L("刷新磁盘"))
            }.padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            HStack(spacing: gap) {
                Text(L("磁盘")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("格式")).frame(width: formatWidth, alignment: .leading)
                Text(L("状态")).frame(width: statusWidth, alignment: .leading)
                Text(L("使用情况")).frame(width: usageWidth, alignment: .leading)
                Text(L("操作")).frame(width: actionWidth, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(.quaternary.opacity(0.25))
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.disks.isEmpty {
                        ContentUnavailableView(L("连接外接硬盘"), systemImage: "externaldrive", description: Text(L("连接后自动显示文件系统与挂载状态。")))
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(model.disks) { volume in
                        diskRow(volume)
                        Divider().padding(.leading, 18)
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Circle().fill(model.ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(model.ready ? L("驱动已就绪") : L("读写组件缺失"))
                Spacer()
                if model.busy { ProgressView().controlSize(.mini) }
                Text(model.message).lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 10)
        }.frame(minWidth: 680 + textButtonWidth * 2, minHeight: 320)
        .environment(\.locale, Locale(identifier: AppLanguage.code))
        .onChange(of: language) { _, _ in model.refresh() }
        .onAppear { model.refresh() }.onReceive(timer) { _ in model.refresh() }
        .sheet(isPresented: $showLanguageSettings) {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("语言")).font(.title2.bold())
                Picker(L("语言"), selection: $language) {
                    Text(L("跟随系统")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }.pickerStyle(.radioGroup).labelsHidden()
                HStack { Spacer(); Button(L("完成")) { showLanguageSettings = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 300)
        }
        .sheet(item: $detail) { v in
            VStack(alignment: .leading, spacing: 16) {
                Label(v.name, systemImage: "externaldrive").font(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    GridRow { Text(L("设备")).foregroundStyle(.secondary); Text(v.id) }
                    GridRow { Text(L("格式")).foregroundStyle(.secondary); Text(v.fs.uppercased()) }
                    GridRow { Text(L("容量")).foregroundStyle(.secondary); Text(capacityText(v.size)) }
                    if let usage = v.usage {
                        GridRow { Text(L("已用")).foregroundStyle(.secondary); Text(capacityText(usage.used)) }
                        GridRow { Text(L("可用")).foregroundStyle(.secondary); Text(capacityText(usage.available)) }
                    }
                    GridRow { Text(L("挂载路径")).foregroundStyle(.secondary); Text(v.path.isEmpty ? L("已卸载") : v.path).textSelection(.enabled) }
                    GridRow { Text(L("卷 UUID")).foregroundStyle(.secondary); Text(v.uuid.isEmpty ? L("未提供") : v.uuid).textSelection(.enabled) }
                }.font(.callout)
                if v.ntfs { Text(L("切换挂载模式会请求系统管理员授权。")).font(.caption).foregroundStyle(.secondary) }
                HStack { Spacer(); Button(L("完成")) { detail = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(minWidth: 500)
        }
        .alert(L("操作提示"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("确定")) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    // Every cell shares a 24-point primary line and a 16-point secondary line.
    // Native controls keep their system focus, pressed and disabled states.
    private func rowCell<P: View, S: View>(@ViewBuilder primary: () -> P, @ViewBuilder secondary: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            primary().frame(height: 24)
            secondary().frame(height: 16)
        }
    }

    private func diskRow(_ v: Volume) -> some View {
        HStack(spacing: gap) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive").font(.system(size: 22)).foregroundStyle(.secondary)
                rowCell {
                    Text(v.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                } secondary: {
                    Text(capacityText(v.size)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).help(v.name + " · " + v.id)
            rowCell {
                Text(v.fs.uppercased()).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(v.ntfs ? Color.blue : Color.secondary)
            } secondary: { Color.clear }
                .frame(width: formatWidth, alignment: .leading)
            rowCell {
                HStack(spacing: 5) {
                    Circle().fill(v.path.isEmpty ? Color.secondary : v.writable ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(v.path.isEmpty ? L("已卸载") : v.writable ? L("可读写") : L("只读"))
                }.font(.system(size: 12))
            } secondary: { Color.clear }
                .frame(width: statusWidth, alignment: .leading)
            rowCell {
                if let usage = v.usage {
                    HStack(spacing: 7) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(usage.fraction > 0.95 ? Color.orange : Color.blue)
                                    .frame(width: proxy.size.width * min(max(usage.fraction, 0), 1))
                            }
                        }.frame(height: 4)
                        Text(String(format: "%.1f%%", locale: Locale(identifier: AppLanguage.code), usage.fraction * 100))
                            .font(.system(size: 12)).monospacedDigit().fixedSize()
                    }.help(L("space.used", capacityText(usage.used), capacityText(usage.total)))
                } else {
                    Text(v.path.isEmpty ? L("挂载后显示容量") : L("容量暂时不可用"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } secondary: {
                if let usage = v.usage {
                    Text(L("space.available", capacityText(usage.available))).font(.system(size: 11))
                        .foregroundStyle(.secondary).monospacedDigit()
                } else { Color.clear }
            }.frame(width: usageWidth, alignment: .leading)
            rowCell {
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: v.path)) } label: {
                        Text(L("打开")).frame(width: textButtonWidth - 20, height: 20).lineLimit(1)
                    }.frame(width: textButtonWidth, height: 30).disabled(v.path.isEmpty).help(L("在 Finder 打开"))
                    if v.ntfs {
                        Button { model.act(v.writable && !v.path.isEmpty ? "ro" : "rw", v) } label: {
                            Text(v.writable && !v.path.isEmpty ? L("只读") : L("读写")).frame(width: textButtonWidth - 20, height: 20).lineLimit(1)
                        }.frame(width: textButtonWidth, height: 30)
                            .disabled(v.uuid.isEmpty || ((!v.writable || v.path.isEmpty) && !model.ready))
                            .help(L("切换挂载模式，需要管理员授权"))
                        Button { model.act("eject", v) } label: { Image(systemName: "eject").frame(width: 32, height: 30) }
                            .buttonStyle(.borderless).help(L("安全推出"))
                    } else {
                        Color.clear.frame(width: textButtonWidth, height: 30)
                        Color.clear.frame(width: 32, height: 30)
                    }
                    Menu {
                        Button(L("磁盘详情…")) { detail = v }
                        if v.ntfs {
                            Divider()
                            Button(L("启用读写")) { model.act("rw", v) }.disabled(!model.ready || v.uuid.isEmpty)
                            Button(L("只读挂载")) { model.act("ro", v) }.disabled(v.uuid.isEmpty)
                            Button(L("安全推出")) { model.act("eject", v) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 30) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .fixedSize().help(L("更多操作")).accessibilityIdentifier("more-" + v.id)
                }.font(.system(size: 13)).controlSize(.regular).disabled(model.busy)
            } secondary: { Color.clear }
                .frame(width: actionWidth, alignment: .leading)
        }.padding(.horizontal, 18).frame(height: 64)
    }

}
@main struct VolumeBridgeApp: App {
    init() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--language"), index + 1 < arguments.count {
            arguments.removeSubrange(index...index + 1)
        }
        if arguments.first == "--helper" {
            do { try helper(Array(arguments.dropFirst())); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if arguments.first == "--scan" {
            do { for v in try volumes() {
                let usage = v.usage.map { "total=\($0.total) used=\($0.used) available=\($0.available)" } ?? "usage=unavailable"
                print("\(v.id)\t\(v.name)\t\(v.fs)\t\(v.writable ? "rw" : "ro")\t\(v.path)\t\(usage)")
            }; exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if arguments.first == "--self-test" {
            do { print(try selfTest()); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if arguments.first == "--test-localization" {
            precondition(AppLanguage.resolve("system", preferred: ["ja-JP", "en-US"]) == "ja")
            precondition(AppLanguage.resolve("system", preferred: ["zh-Hans-CN"]) == "zh-Hans")
            precondition(AppLanguage.resolve("system", preferred: ["fr-FR"]) == "en")
            precondition(AppLanguage.resolve("en", preferred: ["ja-JP"]) == "en")
            for code in AppLanguage.supported {
                precondition(AppLanguage.text("磁盘", code: code) != "磁盘" || code == "zh-Hans")
                precondition(AppLanguage.text("disk.access.hint", code: code) != "disk.access.hint")
            }
            print(L("ntfs.count", 2))
            print(L("processing", "Elements"))
            print(diskAccessHint("/dev/disk7s1"))
            exit(0)
        }
        if arguments.first == "--test-error-mapping" {
            precondition(nativeMountPath([:]) == nil)
            precondition(nativeMountPath(["MountPoint": ""]) == nil)
            precondition(nativeMountPath(["MountPoint": "/Volumes/Elements"]) == "/Volumes/Elements")
            let denied = "Error opening '/dev/disk7s1': Operation not permitted\nThe NTFS partition is in an unsafe state."
            precondition(driverFailure(denied, device: "/dev/disk7s1").contains(L("disk.access.hint", "/dev/disk7s1")))
            let hibernated = "Windows is hibernated, refused to mount."
            precondition(driverFailure(hibernated, device: "/dev/disk7s1") == hibernated)
            print("空挂载点识别、权限错误识别和真实休眠错误保留：通过")
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 960, height: 450) }
}
