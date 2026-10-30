// The macOS platform layer for clipmd, exposed to Zig as plain C functions.
//
// This replaces what used to be hand-rolled bindings on the Zig side: the
// Objective-C runtime (`objc_msgSend`) for AppKit, and direct Carbon and
// libdispatch declarations for the global hotkey, the status-icon flash, and
// the config-file watcher. It is all expressed in ordinary Swift here, with
// each entry point exported via `@_cdecl` so Zig can call it through the
// `extern fn` declarations in `ffi.zig`.
//
// Only built into the macOS binary: `build.zig` compiles this with `swiftc`
// and links the resulting object. The Zig side stays responsible for the
// transform engine, config, service, CLI, and the Linux config watcher; this
// file is the macOS boundary.

import AppKit
import Carbon

// MARK: - Pasteboard

// Pasteboard UTI type strings. The literals avoid depending on the AppKit
// `NSPasteboardType*` constants and match the types the old Zig path declared.
private let typePlain = NSPasteboard.PasteboardType("public.utf8-plain-text")
private let typeHTML = NSPasteboard.PasteboardType("public.html")
private let typeRTF = NSPasteboard.PasteboardType("public.rtf")

/// Read the general pasteboard's plain text. Returns a `malloc`'d C string the
/// caller frees with `clipmd_free`, or `nil` when there is no text.
@_cdecl("clipmd_pb_read_text")
func clipmd_pb_read_text() -> UnsafeMutablePointer<CChar>? {
    guard let s = NSPasteboard.general.string(forType: .string) else { return nil }
    return s.withCString { strdup($0) }
}

/// Replace the general pasteboard with the plain/HTML/RTF representations so
/// each receiving app can pick the richest format it understands.
@_cdecl("clipmd_pb_write_rich")
func clipmd_pb_write_rich(
    _ plain: UnsafePointer<UInt8>?, _ plainLen: Int,
    _ html: UnsafePointer<UInt8>?, _ htmlLen: Int,
    _ rtf: UnsafePointer<UInt8>?, _ rtfLen: Int
) {
    let pb = NSPasteboard.general
    pb.declareTypes([typePlain, typeHTML, typeRTF], owner: nil)
    if let plain, plainLen > 0 {
        pb.setData(Data(bytes: plain, count: plainLen), forType: typePlain)
    }
    if let html, htmlLen > 0 {
        pb.setData(Data(bytes: html, count: htmlLen), forType: typeHTML)
    }
    if let rtf, rtfLen > 0 {
        pb.setData(Data(bytes: rtf, count: rtfLen), forType: typeRTF)
    }
}

/// Free a pointer handed back to Zig (e.g. from `clipmd_pb_read_text`).
@_cdecl("clipmd_free")
func clipmd_free(_ p: UnsafeMutableRawPointer?) {
    free(p)
}

// MARK: - Menu-bar app

/// Menu target. Holds the Zig trigger callback and its context, and forwards
/// the menu action to it. The C function type matches `ffi.TriggerFn`.
private final class ClipmdMenuTarget: NSObject {
    let trigger: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let ctx: UnsafeMutableRawPointer?

    init(trigger: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
         ctx: UnsafeMutableRawPointer?) {
        self.trigger = trigger
        self.ctx = ctx
    }

    @objc func transformClipboard(_ sender: Any?) {
        trigger(ctx)
    }
}

// Kept alive for the process lifetime. The status item in particular must be
// retained or the system frees it, taking the menu-bar item with it (the bug
// that previously crashed the hotkey handler).
private var menuTarget: ClipmdMenuTarget?
private var statusItem: NSStatusItem?

// The resting glyph and a generation counter for the flash auto-revert: each
// flash bumps the counter and its delayed revert no-ops unless it still owns
// the latest generation (so a stale revert can't stomp a fresher flash).
private var idleTitle = ""
private var flashGeneration = 0

private func setStatusTitle(_ text: String) {
    statusItem?.button?.title = text
}

/// Build the accessory app, status item, and menu. The "Transform Clipboard"
/// item calls `trigger(ctx)`; "Quit clipmd" terminates the app.
@_cdecl("clipmd_app_setup")
func clipmd_app_setup(
    _ trigger: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ ctx: UnsafeMutableRawPointer?,
    _ idleTitleArg: UnsafePointer<CChar>?
) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    if let idleTitleArg {
        idleTitle = String(cString: idleTitleArg)
        item.button?.title = idleTitle
    }

    let target = ClipmdMenuTarget(trigger: trigger, ctx: ctx)
    menuTarget = target

    let menu = NSMenu()
    let transformItem = NSMenuItem(
        title: "Transform Clipboard",
        action: #selector(ClipmdMenuTarget.transformClipboard(_:)),
        keyEquivalent: ""
    )
    transformItem.target = target
    menu.addItem(transformItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
        title: "Quit clipmd",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    ))
    item.menu = menu
}

/// Set a transient status-item title (✓ / ∅ / ⚠) and schedule a revert to the
/// idle glyph ~1.5s later. Latest flash wins via the generation counter.
@_cdecl("clipmd_status_flash")
func clipmd_status_flash(_ text: UnsafePointer<CChar>?) {
    guard let text else { return }
    setStatusTitle(String(cString: text))
    flashGeneration += 1
    let generation = flashGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if generation == flashGeneration { setStatusTitle(idleTitle) }
    }
}

/// Run the Cocoa event loop. Blocks until the app terminates.
@_cdecl("clipmd_app_run")
func clipmd_app_run() {
    NSApplication.shared.run()
}

// MARK: - Global hotkey (Carbon)

// A system-wide hotkey via the Carbon Event Manager, which (unlike an NSEvent
// global monitor) needs no Accessibility permission. There is a single hotkey,
// so the fire callback, its context, and the registration live in globals.
private var hotKeyFire: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
private var hotKeyCtx: UnsafeMutableRawPointer?
private var hotKeyRef: EventHotKeyRef?
private var hotKeyHandlerInstalled = false

private func fourCharCode(_ s: String) -> FourCharCode {
    var code: FourCharCode = 0
    for byte in s.utf8.prefix(4) { code = (code << 8) | FourCharCode(byte) }
    return code
}

private let kHotKeyPressed: UInt32 = 6 // kEventHotKeyPressed

@_cdecl("clipmd_hotkey_install")
func clipmd_hotkey_install(
    _ keyCode: UInt32, _ modifiers: UInt32,
    _ fire: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    hotKeyFire = fire
    hotKeyCtx = ctx

    if !hotKeyHandlerInstalled {
        var spec = EventTypeSpec(
            eventClass: fourCharCode("keyb"), // kEventClassKeyboard
            eventKind: kHotKeyPressed
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, _) -> OSStatus in
                hotKeyFire?(hotKeyCtx)
                return noErr
            },
            1, &spec, nil, nil
        )
        if status != noErr { return false }
        hotKeyHandlerInstalled = true
    }
    return clipmd_hotkey_set(keyCode, modifiers)
}

@_cdecl("clipmd_hotkey_set")
func clipmd_hotkey_set(_ keyCode: UInt32, _ modifiers: UInt32) -> Bool {
    if let ref = hotKeyRef {
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
    }
    let hkID = EventHotKeyID(signature: fourCharCode("clpm"), id: 1)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    if status != noErr { return false }
    hotKeyRef = ref
    return true
}

// MARK: - Config-file watcher (libdispatch VNODE)

// Watch the config file for in-place writes, and its parent directory for the
// rename half of an atomic save (editor: write temp + rename over the original,
// which replaces the inode and would otherwise leave a file-only watch stale).
// Handlers run on the main queue so the callback may re-bind the hotkey.
private final class ConfigWatcher {
    private let path: String
    private let onChange: @convention(c) (UnsafeMutableRawPointer?) -> Void
    private let ctx: UnsafeMutableRawPointer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    init(path: String,
         onChange: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
         ctx: UnsafeMutableRawPointer?) {
        self.path = path
        self.onChange = onChange
        self.ctx = ctx
    }

    func start() -> Bool {
        var dir = (path as NSString).deletingLastPathComponent
        if dir.isEmpty { dir = "." }

        // The directory watch is required: it's the only signal we get when the
        // file is atomically swapped in. The dir itself never moves.
        let dirFD = open(dir, O_EVTONLY)
        if dirFD < 0 { return false }
        let dirSrc = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write, .rename, .extend], queue: .main)
        dirSrc.setEventHandler { [weak self] in
            // Something in the dir changed: the config may have been replaced
            // (so our file watch is stale) or this is unrelated churn. Re-open
            // the file watch unconditionally, then fire; the reload itself
            // decides whether the new file parses.
            self?.reopenFile()
            self?.fire()
        }
        dirSrc.setCancelHandler { close(dirFD) }
        dirSource = dirSrc
        dirSrc.resume()

        // The file watch is best-effort: fine if the file doesn't exist yet —
        // the dir source will pick it up on the next save.
        openFileSource()
        return true
    }

    private func fire() {
        onChange(ctx)
    }

    private func openFileSource() {
        let fd = open(path, O_EVTONLY)
        if fd < 0 { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        // Plain WRITE/EXTEND keeps firing on the same inode, so no re-open is
        // needed there; the dir source handles the atomic-replace case.
        src.setEventHandler { [weak self] in self?.fire() }
        src.setCancelHandler { close(fd) }
        fileSource = src
        src.resume()
    }

    private func reopenFile() {
        fileSource?.cancel() // its cancel handler closes the old fd
        fileSource = nil
        openFileSource()
    }
}

private var configWatcher: ConfigWatcher?

@_cdecl("clipmd_watch_start")
func clipmd_watch_start(
    _ path: UnsafePointer<CChar>?,
    _ onChange: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    guard let path else { return false }
    let watcher = ConfigWatcher(path: String(cString: path), onChange: onChange, ctx: ctx)
    guard watcher.start() else { return false }
    configWatcher = watcher
    return true
}
