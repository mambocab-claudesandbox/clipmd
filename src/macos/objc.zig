//! Minimal Objective-C runtime bindings for Zig.
//!
//! Rather than depend on an external package (which this sandboxed build cannot
//! fetch), we declare the handful of runtime symbols we need and provide a
//! comptime `msgSend` helper that casts `objc_msgSend` to the correct function
//! pointer type per call. Only the methods actually used by the app are
//! exercised, keeping this self-contained.

const std = @import("std");

pub const objc_object = opaque {};
pub const objc_class = opaque {};
pub const objc_selector = opaque {};

pub const id = ?*objc_object;
pub const Class = ?*objc_class;
pub const SEL = ?*objc_selector;
pub const IMP = *const fn () callconv(.c) void;

pub extern fn objc_getClass(name: [*:0]const u8) Class;
pub extern fn sel_registerName(name: [*:0]const u8) SEL;
pub extern fn objc_msgSend() void;
pub extern fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
pub extern fn objc_registerClassPair(cls: Class) void;
pub extern fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) bool;
/// Pointer to the extra bytes requested via `objc_allocateClassPair`'s
/// `extra_bytes`. Used to stash a context pointer on an instance.
pub extern fn object_getIndexedIvars(obj: id) ?*anyopaque;
pub extern fn objc_autoreleasePoolPush() ?*anyopaque;
pub extern fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

/// Look up a class by name.
pub inline fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

/// Register/look up a selector by name.
pub inline fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Send an Objective-C message. `target` may be an `id` or `Class`; `sel_name`
/// is the selector; `args` is a tuple of arguments. The return type is given
/// explicitly. Supports up to four arguments, which covers all call sites here.
pub fn msgSend(comptime Ret: type, target: anytype, sel_name: [*:0]const u8, args: anytype) Ret {
    const T = @TypeOf(target);
    const selector = sel_registerName(sel_name);
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    const FnPtr = switch (fields.len) {
        0 => *const fn (T, SEL) callconv(.c) Ret,
        1 => *const fn (T, SEL, fields[0].type) callconv(.c) Ret,
        2 => *const fn (T, SEL, fields[0].type, fields[1].type) callconv(.c) Ret,
        3 => *const fn (T, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) Ret,
        4 => *const fn (T, SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) Ret,
        else => @compileError("msgSend supports at most 4 arguments"),
    };

    const f: FnPtr = @ptrCast(&objc_msgSend);
    return switch (fields.len) {
        0 => f(target, selector),
        1 => f(target, selector, args[0]),
        2 => f(target, selector, args[0], args[1]),
        3 => f(target, selector, args[0], args[1], args[2]),
        4 => f(target, selector, args[0], args[1], args[2], args[3]),
        else => unreachable,
    };
}

pub const NSUTF8StringEncoding: usize = 4;

/// An autorelease pool scope. Idiomatic usage collapses many per-object
/// releases into a single `defer`:
///
///     const pool = objc.AutoreleasePool.init();
///     defer pool.deinit();
///
/// Objects from the autoreleased constructors below (and Cocoa's own
/// convenience constructors) are released when the pool is drained.
pub const AutoreleasePool = struct {
    token: ?*anyopaque,

    pub fn init() AutoreleasePool {
        return .{ .token = objc_autoreleasePoolPush() };
    }
    pub fn deinit(self: AutoreleasePool) void {
        objc_autoreleasePoolPop(self.token);
    }
};

/// Create an autoreleased NSString from a UTF-8 slice. Valid until the
/// enclosing `AutoreleasePool` is drained.
pub fn nsString(bytes: []const u8) id {
    const obj = msgSend(id, getClass("NSString"), "alloc", .{});
    const str = msgSend(id, obj, "initWithBytes:length:encoding:", .{
        @as([*]const u8, bytes.ptr),
        bytes.len,
        NSUTF8StringEncoding,
    });
    return msgSend(id, str, "autorelease", .{});
}

/// Create an autoreleased NSData from a byte slice. Valid until the enclosing
/// `AutoreleasePool` is drained.
pub fn nsData(bytes: []const u8) id {
    const obj = msgSend(id, getClass("NSData"), "alloc", .{});
    const data = msgSend(id, obj, "initWithBytes:length:", .{
        @as([*]const u8, bytes.ptr),
        bytes.len,
    });
    return msgSend(id, data, "autorelease", .{});
}
