// The macOS AppKit layer for clipmd, exposed to Zig as plain C functions.
//
// This replaces the previous approach of driving the Objective-C runtime
// (`objc_msgSend`) directly from Zig. The AppKit work — reading/writing the
// pasteboard and hosting the status-bar menu — is expressed in ordinary Swift
// here, and each entry point is exported with `@_cdecl` so Zig can call it
// through the `extern fn` declarations in `ffi.zig`.
//
// Only built into the macOS binary: `build.zig` compiles this with `swiftc`
// and links the resulting object. The Zig side stays responsible for the
// transform engine, config, hotkey (Carbon), and config watcher (libdispatch);
// this file is just the AppKit boundary.

import AppKit

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

/// Build the accessory app, status item, and menu. The "Transform Clipboard"
/// item calls `trigger(ctx)`; "Quit clipmd" terminates the app.
@_cdecl("clipmd_app_setup")
func clipmd_app_setup(
    _ trigger: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ ctx: UnsafeMutableRawPointer?,
    _ idleTitle: UnsafePointer<CChar>?
) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    if let idleTitle { item.button?.title = String(cString: idleTitle) }

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

/// Set the status-item title (used for the transient ✓ / ∅ / ⚠ flash).
@_cdecl("clipmd_status_set_title")
func clipmd_status_set_title(_ text: UnsafePointer<CChar>?) {
    guard let text, let button = statusItem?.button else { return }
    button.title = String(cString: text)
}

/// Run the Cocoa event loop. Blocks until the app terminates.
@_cdecl("clipmd_app_run")
func clipmd_app_run() {
    NSApplication.shared.run()
}
