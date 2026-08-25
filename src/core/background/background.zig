const background_process_provider = @import("../execution/background_process_provider.zig");

pub const background_exit_marker = background_process_provider.exit_marker;

pub const process_supervisor = @import("process_supervisor.zig");
pub const background_runtime = @import("background_runtime.zig");
pub const background_store = @import("background_store.zig");
pub const task_helpers = @import("../tasks/task_helpers.zig");
pub const background_commands = @import("background_commands.zig");

pub const BackgroundRuntime = background_runtime.BackgroundRuntime;
pub const RuntimeContextSnapshot = background_runtime.RuntimeContextSnapshot;
pub const TaskSnapshot = background_runtime.TaskSnapshot;
pub const TaskListSnapshot = background_runtime.TaskListSnapshot;
pub const TaskState = background_runtime.TaskState;
pub const TaskSelection = background_runtime.TaskSelection;
pub const StopSelection = background_runtime.StopSelection;
pub const TaskCompletion = background_runtime.TaskCompletion;
pub const ProcessSupervisor = process_supervisor.ProcessSupervisor;
pub const Runtime = background_runtime.BackgroundRuntime;

test "background exports runtime owner types" {
    const std = @import("std");
    try std.testing.expect(Runtime == background_runtime.BackgroundRuntime);
    try std.testing.expect(BackgroundRuntime == background_runtime.BackgroundRuntime);
    try std.testing.expect(ProcessSupervisor == process_supervisor.ProcessSupervisor);
    try std.testing.expect(!@hasField(Runtime, "records"));
}
