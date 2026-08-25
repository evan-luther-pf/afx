const build_options = @import("build_options");

pub const name: []const u8 = build_options.product_name;
pub const profile_dir_name: []const u8 = build_options.profile_dir_name;
pub const project_config_name: []const u8 = build_options.project_config_name;
pub const workspace_skills_dir: []const u8 = build_options.workspace_skills_dir;
pub const workspace_agents_dir: []const u8 = build_options.workspace_agents_dir;
pub const global_agents_dir: []const u8 = build_options.global_agents_dir;
pub const is_afx: bool = build_options.is_afx;
pub const wordmark: []const u8 = "𝒂𝒇x";

test "compiled product contract is internally consistent" {
    const std = @import("std");
    try std.testing.expect(is_afx);
    try std.testing.expectEqualStrings("afx", name);
    try std.testing.expectEqualStrings(".afx", profile_dir_name);
    try std.testing.expectEqualStrings(".afx.json", project_config_name);
    try std.testing.expectEqualStrings(".afx/skills", workspace_skills_dir);
    try std.testing.expectEqualStrings(".afx/agents", workspace_agents_dir);
    try std.testing.expectEqualStrings(".afx/agents", global_agents_dir);
    try std.testing.expectEqualStrings("𝒂𝒇x", wordmark);
}
