const std = @import("std");
const JSC = bun.JSC;
const bun = @import("bun");
const Fs = @import("../../fs.zig");
const Path = @import("../../resolver/resolve_path.zig");

const UnboundedQueue = @import("../unbounded_queue.zig").UnboundedQueue;
const EventLoopTimer = @import("../api/Timer.zig").EventLoopTimer;
const VirtualMachine = JSC.VirtualMachine;
const EventLoop = JSC.EventLoop;
const PathLike = JSC.Node.PathLike;
const ArgumentsSlice = JSC.CallFrame.ArgumentsSlice;
const Output = bun.Output;
const string = bun.string;

const StatsSmall = bun.JSC.Node.StatsSmall;
const StatsBig = bun.JSC.Node.StatsBig;

const log = bun.Output.scoped(.StatWatcher, false);

fn statToJSStats(globalThis: *JSC.JSGlobalObject, stats: *const bun.Stat, bigint: bool) bun.JSError!JSC.JSValue {
    if (bigint) {
        return StatsBig.init(stats).toJS(globalThis);
    } else {
        return StatsSmall.init(stats).toJS(globalThis);
    }
}

/// This is a singleton struct that contains the timer used to schedule re-stat calls.
pub const StatWatcherScheduler = struct {
    current_interval: std.atomic.Value(i32) = .{ .raw = 0 },
    task: JSC.WorkPoolTask = .{ .callback = &workPoolCallback },
    main_thread: std.Thread.Id,
    vm: *bun.JSC.VirtualMachine,
    watchers: WatcherQueue = WatcherQueue{},

    event_loop_timer: EventLoopTimer = .{
        .next = .{},
        .tag = .StatWatcherScheduler,
    },

    ref_count: RefCount,

    const RefCount = bun.ptr.ThreadSafeRefCount(StatWatcherScheduler, "ref_count", deinit, .{ .debug_name = "StatWatcherScheduler" });
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    const WatcherQueue = UnboundedQueue(StatWatcher, .next);

    pub fn init(vm: *bun.JSC.VirtualMachine) bun.ptr.RefPtr(StatWatcherScheduler) {
        return .new(.{
            .ref_count = .init(),
            .main_thread = std.Thread.getCurrentId(),
            .vm = vm,
        });
    }

    fn deinit(this: *StatWatcherScheduler) void {
        bun.assertf(this.watchers.count == 0, "destroying StatWatcherScheduler while it still has {} watchers", .{this.watchers.count});
        bun.destroy(this);
    }

    pub fn append(this: *StatWatcherScheduler, watcher: *StatWatcher) void {
        log("append new watcher {s}", .{watcher.path});
        bun.assert(watcher.closed == false);
        bun.assert(watcher.next == null);

        watcher.ref();
        this.watchers.push(watcher);
        log("push watcher {x} -> {d} watchers", .{ @intFromPtr(watcher), this.watchers.count });
        const current = this.getInterval();
        if (current == 0 or current > watcher.interval) {
            // we are not running or the new watcher has a smaller interval
            this.setInterval(watcher.interval);
        }
    }

    fn getInterval(this: *StatWatcherScheduler) i32 {
        return this.current_interval.load(.monotonic);
    }

    /// Update the current interval and set the timer (this function is thread safe)
    fn setInterval(this: *StatWatcherScheduler, interval: i32) void {
        this.ref();
        this.current_interval.store(interval, .monotonic);

        if (this.main_thread == std.Thread.getCurrentId()) {
            // we are in the main thread we can set the timer
            this.setTimer(interval);
            return;
        }
        // we are not in the main thread we need to schedule a task to set the timer
        this.scheduleTimerUpdate();
    }

    /// Set the timer (this function is not thread safe, should be called only from the main thread)
    fn setTimer(this: *StatWatcherScheduler, interval: i32) void {

        // if the interval is 0 means that we stop the timer
        if (interval == 0) {
            // if the timer is active we need to remove it
            if (this.event_loop_timer.state == .ACTIVE) {
                this.vm.timer.remove(&this.event_loop_timer);
            }
            return;
        }

        // reschedule the timer
        this.vm.timer.update(&this.event_loop_timer, &bun.timespec.msFromNow(interval));
    }

    /// Schedule a task to set the timer in the main thread
    fn scheduleTimerUpdate(this: *StatWatcherScheduler) void {
        const Holder = struct {
            scheduler: *StatWatcherScheduler,
            task: JSC.AnyTask,

            pub fn updateTimer(self: *@This()) void {
                defer bun.default_allocator.destroy(self);
                self.scheduler.setTimer(self.scheduler.getInterval());
            }
        };
        const holder = bun.default_allocator.create(Holder) catch bun.outOfMemory();
        holder.* = .{
            .scheduler = this,
            .task = JSC.AnyTask.New(Holder, Holder.updateTimer).init(holder),
        };
        this.vm.enqueueTaskConcurrent(JSC.ConcurrentTask.create(JSC.Task.init(&holder.task)));
    }

    pub fn timerCallback(this: *StatWatcherScheduler) EventLoopTimer.Arm {
        const has_been_cleared = this.event_loop_timer.state == .CANCELLED or this.vm.scriptExecutionStatus() != .running;

        this.event_loop_timer.state = .FIRED;
        this.event_loop_timer.heap = .{};

        if (has_been_cleared) {
            return .disarm;
        }

        JSC.WorkPool.schedule(&this.task);

        return .disarm;
    }

    pub fn workPoolCallback(task: *JSC.WorkPoolTask) void {
        var this: *StatWatcherScheduler = @alignCast(@fieldParentPtr("task", task));
        // ref'd when the timer was scheduled
        defer this.deref();
        // Instant.now will not fail on our target platforms.
        const now = std.time.Instant.now() catch unreachable;

        var batch = this.watchers.popBatch();
        log("pop batch of {d} -> {d} watchers", .{ batch.count, this.watchers.count });
        var iter = batch.iterator();
        var min_interval: i32 = std.math.maxInt(i32);
        var closest_next_check: u64 = @intCast(min_interval);
        var contain_watchers = false;
        while (iter.next()) |watcher| {
            if (watcher.closed) {
                watcher.deref();
                continue;
            }
            contain_watchers = true;

            const time_since = now.since(watcher.last_check);
            const interval = @as(u64, @intCast(watcher.interval)) * 1_000_000;

            if (time_since >= interval -| 500) {
                watcher.last_check = now;
                watcher.restat();
            } else {
                closest_next_check = @min(interval - @as(u64, time_since), closest_next_check);
            }
            min_interval = @min(min_interval, watcher.interval);
            this.watchers.push(watcher);
            log("reinsert {x} -> {d} watchers", .{ @intFromPtr(watcher), this.watchers.count });
        }

        if (contain_watchers) {
            // choose the smallest interval or the closest time to the next check
            this.setInterval(@min(min_interval, @as(i32, @intCast(closest_next_check))));
        } else {
            // we do not have watchers, we can stop the timer
            this.setInterval(0);
        }
    }
};

// TODO: make this a top-level struct
pub const StatWatcher = struct {
    pub const Scheduler = StatWatcherScheduler;

    next: ?*StatWatcher = null,

    ctx: *VirtualMachine,

    ref_count: RefCount,

    /// Closed is set to true to tell the scheduler to remove from list and deref.
    closed: bool,
    path: [:0]u8,
    persistent: bool,
    bigint: bool,
    interval: i32,
    last_check: std.time.Instant,

    globalThis: *JSC.JSGlobalObject,
    js_this: JSC.JSValue,

    poll_ref: bun.Async.KeepAlive = .{},

    last_stat: bun.Stat,
    last_jsvalue: JSC.Strong.Optional,

    scheduler: bun.ptr.RefPtr(StatWatcherScheduler),

    const RefCount = bun.ptr.ThreadSafeRefCount(StatWatcher, "ref_count", deinit, .{ .debug_name = "StatWatcher" });
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    pub const js = JSC.Codegen.JSStatWatcher;
    pub const toJS = js.toJS;
    pub const fromJS = js.fromJS;
    pub const fromJSDirect = js.fromJSDirect;

    pub fn eventLoop(this: StatWatcher) *EventLoop {
        return this.ctx.eventLoop();
    }

    pub fn enqueueTaskConcurrent(this: StatWatcher, task: *JSC.ConcurrentTask) void {
        this.eventLoop().enqueueTaskConcurrent(task);
    }

    pub fn deinit(this: *StatWatcher) void {
        log("deinit {x}", .{@intFromPtr(this)});

        if (this.persistent) {
            this.persistent = false;
            this.poll_ref.unref(this.ctx);
        }
        this.closed = true;
        this.last_jsvalue.deinit();

        bun.default_allocator.free(this.path);
        bun.default_allocator.destroy(this);
    }

    pub const Arguments = struct {
        path: PathLike,
        listener: JSC.JSValue,

        persistent: bool,
        bigint: bool,
        interval: i32,

        global_this: *JSC.JSGlobalObject,

        pub fn fromJS(global: *JSC.JSGlobalObject, arguments: *ArgumentsSlice) bun.JSError!Arguments {
            const path = try PathLike.fromJSWithAllocator(global, arguments, bun.default_allocator) orelse {
                return global.throwInvalidArguments("filename must be a string or TypedArray", .{});
            };

            var listener: JSC.JSValue = .zero;
            var persistent: bool = true;
            var bigint: bool = false;
            var interval: i32 = 5007;

            if (arguments.nextEat()) |options_or_callable| {
                // options
                if (options_or_callable.isObject()) {
                    // default true
                    persistent = (try options_or_callable.getBooleanStrict(global, "persistent")) orelse true;

                    // default false
                    bigint = (try options_or_callable.getBooleanStrict(global, "bigint")) orelse false;

                    if (try options_or_callable.get(global, "interval")) |interval_| {
                        if (!interval_.isNumber() and !interval_.isAnyInt()) {
                            return global.throwInvalidArguments("interval must be a number", .{});
                        }
                        interval = try interval_.coerce(i32, global);
                    }
                }
            }

            if (arguments.nextEat()) |listener_| {
                if (listener_.isCallable()) {
                    listener = listener_.withAsyncContextIfNeeded(global);
                }
            }

            if (listener == .zero) {
                return global.throwInvalidArguments("Expected \"listener\" callback", .{});
            }

            return Arguments{
                .path = path,
                .listener = listener,
                .persistent = persistent,
                .bigint = bigint,
                .interval = interval,
                .global_this = global,
            };
        }

        pub fn createStatWatcher(this: Arguments) !JSC.JSValue {
            const obj = try StatWatcher.init(this);
            if (obj.js_this != .zero) {
                return obj.js_this;
            }
            return .js_undefined;
        }
    };

    pub fn doRef(this: *StatWatcher, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        if (!this.closed and !this.persistent) {
            this.persistent = true;
            this.poll_ref.ref(this.ctx);
        }
        return .js_undefined;
    }

    pub fn doUnref(this: *StatWatcher, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        if (this.persistent) {
            this.persistent = false;
            this.poll_ref.unref(this.ctx);
        }
        return .js_undefined;
    }

    /// Stops file watching but does not free the instance.
    pub fn close(this: *StatWatcher) void {
        if (this.persistent) {
            this.persistent = false;
            this.poll_ref.unref(this.ctx);
        }
        this.closed = true;
        this.last_jsvalue.clearWithoutDeallocation();
    }

    pub fn doClose(this: *StatWatcher, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        this.close();
        return .js_undefined;
    }

    /// If the scheduler is not using this, free instantly, otherwise mark for being freed.
    pub fn finalize(this: *StatWatcher) void {
        log("Finalize\n", .{});
        this.closed = true;
        this.scheduler.deref();
        this.deref(); // but don't deinit until the scheduler drops its reference
    }

    pub const InitialStatTask = struct {
        watcher: *StatWatcher,
        task: JSC.WorkPoolTask = .{ .callback = &workPoolCallback },

        pub fn createAndSchedule(watcher: *StatWatcher) void {
            const task = bun.new(InitialStatTask, .{ .watcher = watcher });
            JSC.WorkPool.schedule(&task.task);
        }

        fn workPoolCallback(task: *JSC.WorkPoolTask) void {
            const initial_stat_task: *InitialStatTask = @fieldParentPtr("task", task);
            defer bun.destroy(initial_stat_task);
            const this = initial_stat_task.watcher;

            if (this.closed) {
                return;
            }

            const stat = bun.sys.stat(this.path);
            switch (stat) {
                .result => |res| {
                    // we store the stat, but do not call the callback
                    this.last_stat = res;
                    this.enqueueTaskConcurrent(JSC.ConcurrentTask.fromCallback(this, initialStatSuccessOnMainThread));
                },
                .err => {
                    // on enoent, eperm, we call cb with two zeroed stat objects
                    // and store previous stat as a zeroed stat object, and then call the callback.
                    this.last_stat = std.mem.zeroes(bun.Stat);
                    this.enqueueTaskConcurrent(JSC.ConcurrentTask.fromCallback(this, initialStatErrorOnMainThread));
                },
            }
        }
    };

    pub fn initialStatSuccessOnMainThread(this: *StatWatcher) void {
        if (this.closed) {
            return;
        }

        const jsvalue = statToJSStats(this.globalThis, &this.last_stat, this.bigint) catch return; // TODO: properly propagate exception upwards
        this.last_jsvalue = .create(jsvalue, this.globalThis);

        this.scheduler.data.append(this);
    }

    pub fn initialStatErrorOnMainThread(this: *StatWatcher) void {
        if (this.closed) {
            return;
        }

        const jsvalue = statToJSStats(this.globalThis, &this.last_stat, this.bigint) catch return; // TODO: properly propagate exception upwards
        this.last_jsvalue = .create(jsvalue, this.globalThis);

        _ = js.listenerGetCached(this.js_this).?.call(
            this.globalThis,
            .js_undefined,
            &[2]JSC.JSValue{
                jsvalue,
                jsvalue,
            },
        ) catch |err| this.globalThis.reportActiveExceptionAsUnhandled(err);

        if (this.closed) {
            return;
        }
        this.scheduler.data.append(this);
    }

    /// Called from any thread
    pub fn restat(this: *StatWatcher) void {
        log("recalling stat", .{});
        const stat = bun.sys.stat(this.path);
        const res = switch (stat) {
            .result => |res| res,
            .err => std.mem.zeroes(bun.Stat),
        };

        var compare = res;
        const StatT = @TypeOf(compare);
        if (@hasField(StatT, "st_atim")) {
            compare.st_atim = this.last_stat.st_atim;
        } else if (@hasField(StatT, "st_atimespec")) {
            compare.st_atimespec = this.last_stat.st_atimespec;
        } else if (@hasField(StatT, "atim")) {
            compare.atim = this.last_stat.atim;
        }

        if (std.mem.eql(u8, std.mem.asBytes(&compare), std.mem.asBytes(&this.last_stat))) return;

        this.last_stat = res;
        this.enqueueTaskConcurrent(JSC.ConcurrentTask.fromCallback(this, swapAndCallListenerOnMainThread));
    }

    /// After a restat found the file changed, this calls the listener function.
    pub fn swapAndCallListenerOnMainThread(this: *StatWatcher) void {
        const prev_jsvalue = this.last_jsvalue.swap();
        const current_jsvalue = statToJSStats(this.globalThis, &this.last_stat, this.bigint) catch return; // TODO: properly propagate exception upwards
        this.last_jsvalue.set(this.globalThis, current_jsvalue);

        _ = js.listenerGetCached(this.js_this).?.call(
            this.globalThis,
            .js_undefined,
            &[2]JSC.JSValue{
                current_jsvalue,
                prev_jsvalue,
            },
        ) catch |err| this.globalThis.reportActiveExceptionAsUnhandled(err);
    }

    pub fn init(args: Arguments) !*StatWatcher {
        log("init", .{});

        const buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(buf);
        var slice = args.path.slice();
        if (bun.strings.startsWith(slice, "file://")) {
            slice = slice[6..];
        }

        var parts = [_]string{slice};
        const file_path = Path.joinAbsStringBuf(
            Fs.FileSystem.instance.top_level_dir,
            buf,
            &parts,
            .auto,
        );

        const alloc_file_path = try bun.default_allocator.allocSentinel(u8, file_path.len, 0);
        errdefer bun.default_allocator.free(alloc_file_path);
        @memcpy(alloc_file_path, file_path);

        var this = try bun.default_allocator.create(StatWatcher);
        const vm = args.global_this.bunVM();
        this.* = .{
            .ctx = vm,
            .persistent = args.persistent,
            .bigint = args.bigint,
            .interval = @max(5, args.interval),
            .globalThis = args.global_this,
            .js_this = .zero,
            .closed = false,
            .path = alloc_file_path,
            // Instant.now will not fail on our target platforms.
            .last_check = std.time.Instant.now() catch unreachable,
            // InitStatTask is responsible for setting this
            .last_stat = std.mem.zeroes(bun.Stat),
            .last_jsvalue = .empty,
            .scheduler = vm.rareData().nodeFSStatWatcherScheduler(vm),
            .ref_count = .init(),
        };
        errdefer this.deinit();

        if (this.persistent) {
            this.poll_ref.ref(this.ctx);
        }

        const js_this = StatWatcher.toJS(this, this.globalThis);
        this.js_this = js_this;
        js.listenerSetCached(js_this, this.globalThis, args.listener);
        InitialStatTask.createAndSchedule(this);

        return this;
    }
};
