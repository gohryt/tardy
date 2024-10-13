const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.tardy);

pub const Runtime = @import("runtime/lib.zig").Runtime;
pub const Task = @import("runtime/task.zig").Task;

const auto_async_match = @import("aio/lib.zig").auto_async_match;
const async_to_type = @import("aio/lib.zig").async_to_type;
const AsyncIO = @import("aio/lib.zig").AsyncIO;
const AsyncIOType = @import("aio/lib.zig").AsyncIOType;
const AsyncIOOptions = @import("aio/lib.zig").AsyncIOOptions;
const AsyncBusyLoop = @import("aio/busy_loop.zig").AsyncBusyLoop;
const AsyncEpoll = @import("aio/epoll.zig").AsyncEpoll;
const AsyncIoUring = @import("aio/io_uring.zig").AsyncIoUring;
const Completion = @import("aio/completion.zig").Completion;

const TardyThreadCount = union(enum) {
    /// Calculated by `(cpu_count / 2) - 1`
    auto,
    count: u32,
};

const TardyThreading = union(enum) {
    single_threaded,
    multi_threaded: TardyThreadCount,
};

const TardyOptions = struct {
    /// The allocator that server will use.
    allocator: std.mem.Allocator,
    /// Threading Mode that Tardy runtime will use.
    ///
    /// Default = .{ .multi_threaded = .auto }
    threading: TardyThreading = .{ .multi_threaded = .auto },
    /// Number of Maximum Tasks.
    ///
    /// Default: 1024
    size_tasks_max: u16 = 1024,
    /// Number of Maximum Asynchronous I/O Jobs.
    ///
    /// Default: 1024
    size_aio_jobs_max: u16 = 1024,
    /// Maximum number of aio completions we can reap
    /// with a single call of reap().
    ///
    /// Default: 256
    size_aio_reap_max: u16 = 256,
};

pub fn Tardy(comptime _aio_type: AsyncIOType) type {
    const aio_type: AsyncIOType = comptime if (_aio_type == .auto) auto_async_match() else _aio_type;
    const AioInnerType = comptime async_to_type(aio_type);
    return struct {
        const Self = @This();
        aios: std.ArrayListUnmanaged(*AioInnerType),
        options: TardyOptions,

        pub fn init(options: TardyOptions) !Self {
            log.debug("aio backend: {s}", .{@tagName(aio_type)});

            return .{
                .options = options,
                .aios = try std.ArrayListUnmanaged(*AioInnerType).initCapacity(options.allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.aios.items) |aio| {
                self.options.allocator.destroy(aio);
            }

            self.aios.deinit(self.options.allocator);
        }

        /// This will spawn a new Runtime.
        fn spawn_runtime(self: *Self, options: AsyncIOOptions) !Runtime {
            var aio: AsyncIO = blk: {
                var io = try self.options.allocator.create(AioInnerType);
                io.* = try AioInnerType.init(self.options.allocator, options);
                try self.aios.append(self.options.allocator, io);
                break :blk io.to_async();
            };

            aio.attach(try self.options.allocator.alloc(Completion, self.options.size_aio_reap_max));

            const runtime = try Runtime.init(aio, .{
                .allocator = self.options.allocator,
                .size_tasks_max = self.options.size_tasks_max,
                .size_aio_jobs_max = self.options.size_aio_jobs_max,
                .size_aio_reap_max = self.options.size_aio_reap_max,
            });

            return runtime;
        }

        /// This is the entry into all of the runtimes.
        ///
        /// The provided func needs to have a signature of (*Runtime, std.mem.Allocator, anytype) !void;
        ///
        /// The provided allocator is meant to just initialize any structures that will exist throughout the lifetime
        /// of the runtime. It happens in an arena and is cleaned up after the runtime terminates.
        pub fn entry(self: *Self, func: anytype, params: anytype) !void {
            const thread_count: usize = blk: {
                switch (self.options.threading) {
                    .single_threaded => break :blk 1,
                    .multi_threaded => |threading| {
                        switch (threading) {
                            .auto => break :blk @max(try std.Thread.getCpuCount() / 2 - 1, 1),
                            .count => |count| break :blk count,
                        }
                    },
                }
            };

            log.info("thread count: {d}", .{thread_count});

            var threads = try std.ArrayListUnmanaged(std.Thread).initCapacity(
                self.options.allocator,
                thread_count -| 1,
            );
            defer {
                for (threads.items) |thread| {
                    thread.join();
                }

                threads.deinit(self.options.allocator);
            }

            var runtime = try self.spawn_runtime(.{
                .parent_async = null,
                .size_aio_jobs_max = self.options.size_aio_jobs_max,
                .size_aio_reap_max = self.options.size_aio_reap_max,
            });
            defer runtime.deinit();

            for (0..thread_count - 1) |_| {
                const handle = try std.Thread.spawn(.{}, struct {
                    fn thread_init(
                        tardy: *Self,
                        options: TardyOptions,
                        parent: *AsyncIO,
                        parameters: anytype,
                    ) void {
                        var arena = std.heap.ArenaAllocator.init(options.allocator);

                        var thread_rt = tardy.spawn_runtime(.{
                            .parent_async = parent,
                            .size_aio_jobs_max = options.size_aio_jobs_max,
                            .size_aio_reap_max = options.size_aio_reap_max,
                        }) catch return;
                        defer thread_rt.deinit();

                        @call(.auto, func, .{ &thread_rt, arena.allocator(), parameters }) catch return;
                        thread_rt.run() catch return;
                    }
                }.thread_init, .{ self, self.options, &runtime.aio, params });

                threads.appendAssumeCapacity(handle);
            }

            var arena = std.heap.ArenaAllocator.init(self.options.allocator);
            try @call(.auto, func, .{ &runtime, arena.allocator(), params });
            try runtime.run();
        }
    };
}
