const bun = @import("bun");
const logger = bun.logger;
const std = @import("std");
const string = bun.string;
const Resolver = @import("../resolver//resolver.zig").Resolver;
const JSC = bun.JSC;
const JSGlobalObject = JSC.JSGlobalObject;
const default_allocator = bun.default_allocator;
const ZigString = JSC.ZigString;
const JSValue = JSC.JSValue;

pub const BuildMessage = struct {
    pub const js = JSC.Codegen.JSBuildMessage;
    pub const toJS = js.toJS;
    pub const fromJS = js.fromJS;
    pub const fromJSDirect = js.fromJSDirect;

    msg: logger.Msg,
    // resolve_result: Resolver.Result,
    allocator: std.mem.Allocator,
    logged: bool = false,

    pub fn constructor(globalThis: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!*BuildMessage {
        return globalThis.throw("BuildMessage is not constructable", .{});
    }

    pub fn getNotes(this: *BuildMessage, globalThis: *JSC.JSGlobalObject) bun.JSError!JSC.JSValue {
        const notes = this.msg.notes;
        const array = try JSC.JSValue.createEmptyArray(globalThis, notes.len);
        for (notes, 0..) |note, i| {
            const cloned = try note.clone(bun.default_allocator);
            try array.putIndex(
                globalThis,
                @intCast(i),
                try BuildMessage.create(globalThis, bun.default_allocator, logger.Msg{ .data = cloned, .kind = .note }),
            );
        }

        return array;
    }

    pub fn toStringFn(this: *BuildMessage, globalThis: *JSC.JSGlobalObject) JSC.JSValue {
        const text = std.fmt.allocPrint(default_allocator, "BuildMessage: {s}", .{this.msg.data.text}) catch {
            return globalThis.throwOutOfMemoryValue();
        };
        var str = ZigString.init(text);
        str.setOutputEncoding();
        if (str.isUTF8()) {
            const out = str.toJS(globalThis);
            default_allocator.free(text);
            return out;
        }

        return str.toExternalValue(globalThis);
    }

    pub fn create(
        globalThis: *JSC.JSGlobalObject,
        allocator: std.mem.Allocator,
        msg: logger.Msg,
        // resolve_result: *const Resolver.Result,
    ) bun.OOM!JSC.JSValue {
        var build_error = try allocator.create(BuildMessage);
        build_error.* = BuildMessage{
            .msg = try msg.clone(allocator),
            // .resolve_result = resolve_result.*,
            .allocator = allocator,
        };

        return build_error.toJS(globalThis);
    }

    pub fn toString(
        this: *BuildMessage,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        return this.toStringFn(globalThis);
    }

    pub fn toPrimitive(
        this: *BuildMessage,
        globalThis: *JSC.JSGlobalObject,
        callframe: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        const args_ = callframe.arguments_old(1);
        const args = args_.ptr[0..args_.len];
        if (args.len > 0) {
            if (!args[0].isString()) {
                return JSC.JSValue.jsNull();
            }

            const str = try args[0].getZigString(globalThis);
            if (str.eqlComptime("default") or str.eqlComptime("string")) {
                return this.toStringFn(globalThis);
            }
        }

        return JSC.JSValue.jsNull();
    }

    pub fn toJSON(
        this: *BuildMessage,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        var object = JSC.JSValue.createEmptyObject(globalThis, 4);
        object.put(globalThis, ZigString.static("name"), bun.String.static("BuildMessage").toJS(globalThis));
        object.put(globalThis, ZigString.static("position"), this.getPosition(globalThis));
        object.put(globalThis, ZigString.static("message"), this.getMessage(globalThis));
        object.put(globalThis, ZigString.static("level"), this.getLevel(globalThis));
        return object;
    }

    pub fn generatePositionObject(msg: logger.Msg, globalThis: *JSC.JSGlobalObject) JSC.JSValue {
        const location = msg.data.location orelse return JSC.JSValue.jsNull();
        var object = JSC.JSValue.createEmptyObject(globalThis, 7);

        object.put(
            globalThis,
            ZigString.static("lineText"),
            ZigString.init(location.line_text orelse "").toJS(globalThis),
        );
        object.put(
            globalThis,
            ZigString.static("file"),
            ZigString.init(location.file).toJS(globalThis),
        );
        object.put(
            globalThis,
            ZigString.static("namespace"),
            ZigString.init(location.namespace).toJS(globalThis),
        );
        object.put(
            globalThis,
            ZigString.static("line"),
            JSValue.jsNumber(location.line),
        );
        object.put(
            globalThis,
            ZigString.static("column"),
            JSValue.jsNumber(location.column),
        );
        object.put(
            globalThis,
            ZigString.static("length"),
            JSValue.jsNumber(location.length),
        );
        object.put(
            globalThis,
            ZigString.static("offset"),
            JSValue.jsNumber(location.offset),
        );

        return object;
    }

    // https://github.com/oven-sh/bun/issues/2375#issuecomment-2121530202
    pub fn getColumn(this: *BuildMessage, _: *JSC.JSGlobalObject) JSC.JSValue {
        if (this.msg.data.location) |location| {
            return JSC.JSValue.jsNumber(@max(location.column - 1, 0));
        }

        return JSC.JSValue.jsNumber(@as(i32, 0));
    }

    pub fn getLine(this: *BuildMessage, _: *JSC.JSGlobalObject) JSC.JSValue {
        if (this.msg.data.location) |location| {
            return JSC.JSValue.jsNumber(@max(location.line - 1, 0));
        }

        return JSC.JSValue.jsNumber(@as(i32, 0));
    }

    pub fn getPosition(
        this: *BuildMessage,
        globalThis: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        return BuildMessage.generatePositionObject(this.msg, globalThis);
    }

    pub fn getMessage(
        this: *BuildMessage,
        globalThis: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        return ZigString.init(this.msg.data.text).toJS(globalThis);
    }

    pub fn getLevel(
        this: *BuildMessage,
        globalThis: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        return ZigString.init(this.msg.kind.string()).toJS(globalThis);
    }

    pub fn finalize(this: *BuildMessage) void {
        this.msg.deinit(bun.default_allocator);
    }
};
