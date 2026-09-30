// Compiled with functions extracted from the current production Swift source.
// Every command, raw-device access, and identity lookup below is simulated.
import Foundation

func L(_ key: String, _ args: CVarArg...) -> String {
    let path = ProcessInfo.processInfo.environment["VOLUMEBRIDGE_TEST_LOCALIZATIONS"]!
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let table = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
    return String(format: table[key] ?? key, arguments: args)
}
struct CommandResult { let code: Int32; let data: Data; var text: String { String(decoding: data, as: UTF8.self) } }
struct DeskError: LocalizedError { let message: String; var errorDescription: String? { message } }
var fakeEUID: UInt32 = 0
func geteuid() -> UInt32 { fakeEUID }
let volumeUUID = "test-volume-uuid"
var nativeMounted = false
var fuseMounted = false
var emptyMountPoint = true
var isInternal = false
var filesystem = "ntfs"
var identityChanged = false
var reads = 0
var denyRawAccess = false
var rejectUnmount = false
var concurrentUnmount = false
var readonlyMountMissing = false
var driverError: String?
var mountTimeout = false
var calls: [String] = []
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("VolumeBridge-Regression-" + UUID().uuidString)
func mountPath(_ id: String) -> String { scratch.appendingPathComponent(id).path }
func ownedMount(_ id: String) -> Bool { fuseMounted }
func hasMount(_ path: String) -> Bool {
    path == "/SIMULATED/native" ? nativeMounted : (path == mountPath("disk99s1") && fuseMounted)
}
func runtimeReady() -> Bool { true }
func backend() -> String { "/SIMULATED/ntfs-3g" }
func info(_ id: String) throws -> [String: Any] {
    reads += 1
    var result: [String: Any] = ["Internal": isInternal, "FilesystemType": filesystem,
        "VolumeUUID": identityChanged && reads > 1 ? "replacement-uuid" : volumeUUID,
        "ParentWholeDisk": "disk99", "WritableVolume": false]
    if nativeMounted { result["MountPoint"] = "/SIMULATED/native" }
    else if emptyMountPoint { result["MountPoint"] = "" }
    return result
}
func checkRawReadAccess(_ device: String) throws {
    calls.append("raw-check")
    if nativeMounted || fuseMounted { throw DeskError(message: "Resource busy") }
    if denyRawAccess { throw DeskError(message: "simulated privacy denial") }
}
func waitMount(_ path: String) throws {
    calls.append("wait-mount")
    if mountTimeout { throw DeskError(message: "simulated mount timeout") }
    if !fuseMounted { throw DeskError(message: "missing mount") }
}
func run(_ path: String, _ args: [String]) throws -> CommandResult {
    if path == "/usr/sbin/diskutil" {
        do { return try checked(path, args) }
        catch { return CommandResult(code: 1, data: Data(error.localizedDescription.utf8)) }
    }
    guard path == backend() else { throw DeskError(message: "Unexpected command: " + path) }
    calls.append("driver")
    if let text = driverError { return CommandResult(code: 1, data: Data(text.utf8)) }
    if nativeMounted || fuseMounted { throw DeskError(message: "driver called on mounted device") }
    fuseMounted = true
    return CommandResult(code: 0, data: Data())
}
func checked(_ path: String, _ args: [String]) throws -> CommandResult {
    if path == "/sbin/umount" {
        calls.append("unmount-fuse")
        guard fuseMounted, !rejectUnmount else { throw DeskError(message: "Resource busy") }
        fuseMounted = false
    } else if path == "/usr/sbin/diskutil" {
        switch args.first {
        case "unmount":
            calls.append("unmount-native")
            if concurrentUnmount {
                nativeMounted = false
                throw DeskError(message: "disk99s1 was already unmounted")
            }
            if rejectUnmount { throw DeskError(message: "Resource busy") }
            guard nativeMounted else { throw DeskError(message: "disk99s1 was already unmounted") }
            nativeMounted = false
        case "mount": calls.append("mount-ro"); nativeMounted = !readonlyMountMissing
        case "eject": calls.append("eject"); nativeMounted = false
        default: throw DeskError(message: "Unexpected diskutil arguments")
        }
    } else { throw DeskError(message: "Unexpected command: " + path) }
    return CommandResult(code: 0, data: Data())
}

// PRODUCTION_FUNCTIONS

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DeskError(message: message + "; calls=" + calls.joined(separator: ",")) }
}
func act(_ action: String, uuid: String = volumeUUID) throws {
    try helper([action, "disk99s1", uuid, "501", "20"])
}
func rejected(_ action: () throws -> Void) -> String? {
    do { try action(); return nil } catch { return error.localizedDescription }
}
func test(_ name: String) throws {
    switch name {
    case "fuse_to_readonly":
        fuseMounted = true
        try act("ro")
        try expect(calls == ["unmount-fuse", "mount-ro"], "FUSE to readonly must unmount exactly once")
    case "unmounted_empty_to_readonly":
        try act("ro")
        try expect(calls == ["mount-ro"], "Empty MountPoint represents an unmounted volume")
    case "unmounted_missing_to_readonly":
        emptyMountPoint = false
        try act("ro")
        try expect(calls == ["mount-ro"], "Missing MountPoint represents an unmounted volume")
    case "native_to_readonly":
        nativeMounted = true
        try act("ro")
        try expect(calls == ["unmount-native", "mount-ro"], "Native to readonly transition")
    case "concurrent_unmount_success":
        nativeMounted = true; concurrentUnmount = true
        try act("ro")
        try expect(calls == ["unmount-native", "mount-ro"], "Concurrent unmount is accepted after checking final state")
    case "failed_readonly_state_detected":
        readonlyMountMissing = true
        try expect(rejected { try act("ro") } != nil, "A zero exit code must still yield a mounted readonly volume")
    case "native_to_readwrite":
        nativeMounted = true
        try act("rw")
        try expect(calls == ["unmount-native", "raw-check", "driver", "wait-mount"], "Check raw access after unmount")
    case "unmounted_empty_to_readwrite":
        try act("rw")
        try expect(calls == ["raw-check", "driver", "wait-mount"], "Already unmounted volume must reach driver")
    case "fuse_to_readwrite":
        fuseMounted = true
        try act("rw")
        try expect(calls == ["unmount-fuse", "raw-check", "driver", "wait-mount"], "FUSE readwrite retry must unmount exactly once")
    case "unmount_busy_stops_driver":
        nativeMounted = true; rejectUnmount = true
        try expect(rejected { try act("rw") } != nil, "Busy unmount must fail")
        try expect(calls == ["unmount-native"], "Unmount failure must stop driver and raw access")
    case "permission_denial_restores_readonly":
        nativeMounted = true; denyRawAccess = true
        try expect(rejected { try act("rw") } != nil, "Raw access denial must fail")
        try expect(calls == ["unmount-native", "raw-check", "mount-ro"], "Restore readonly after access denial")
    case "driver_failure_restores_readonly":
        nativeMounted = true; driverError = "Windows is hibernated, refused to mount."
        try expect(rejected { try act("rw") } == driverError, "Preserve actual hibernation diagnostics")
        try expect(calls.last == "mount-ro" && !fuseMounted, "Driver error must restore readonly")
    case "mount_timeout_restores_readonly":
        nativeMounted = true; mountTimeout = true
        try expect(rejected { try act("rw") } != nil, "Mount timeout must fail")
        try expect(calls.suffix(2) == ["unmount-fuse", "mount-ro"], "Clean up a partial mount before readonly restore")
    case "changed_uuid_stops_driver":
        nativeMounted = true; identityChanged = true
        try expect(rejected { try act("rw") } != nil, "Changed UUID must fail")
        try expect(!calls.contains("driver") && !calls.contains("mount-ro"), "Replacement disk must receive no driver or recovery mount")
    case "internal_disk_rejected":
        isInternal = true
        try expect(rejected { try act("rw") } != nil && calls.isEmpty, "Reject internal disk before commands")
    case "wrong_uuid_rejected":
        try expect(rejected { try act("rw", uuid: "wrong") } != nil && calls.isEmpty, "Reject wrong UUID before commands")
    case "non_ntfs_rejected":
        filesystem = "exfat"
        try expect(rejected { try act("rw") } != nil && calls.isEmpty, "Reject exFAT before commands")
    case "non_admin_rejected":
        fakeEUID = 501
        try expect(rejected { try act("rw") } != nil && calls.isEmpty, "Reject non-admin helper before commands")
    case "fuse_eject":
        fuseMounted = true
        try act("eject")
        try expect(calls == ["unmount-fuse", "eject"], "Eject FUSE volume after one unmount")
    case "permission_error_mapping":
        let text = "Error opening '/dev/disk99s1': Operation not permitted\nThe NTFS partition is in an unsafe state."
        let mapped = driverFailure(text, device: "/dev/disk99s1")
        try expect(mapped.contains("完整磁盘访问") && !mapped.contains("unsafe state"), "Explain raw-device permissions")
    default: throw DeskError(message: "Unknown test case: " + name)
    }
}
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: scratch) }
do { try test(CommandLine.arguments[1]); print("PASS"); exit(0) }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
