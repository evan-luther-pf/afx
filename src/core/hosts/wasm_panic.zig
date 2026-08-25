const std = @import("std");

/// The default ReleaseSafe panic handler locks stderr and parks double
/// panics through `std.Options.debug_io`, whose wasm futex wait requires
/// the `atomics` CPU feature that the baseline wasm32 target lacks. Write
/// the message straight to stderr and trap instead.
pub const panic = std.debug.FullPanic(panicToStderr);

fn panicToStderr(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    std.debug.print("panic: {s}\n", .{msg});
    @trap();
}
