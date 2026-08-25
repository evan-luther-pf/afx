pub const git_commit: []const u8 = "test";
pub const app_version: []const u8 = "0.0.0-test";
pub const update_channel: []const u8 = "stable";

pub const WasmSurface = enum {
    none,
    core,
    term,
};

pub const wasm_surface: WasmSurface = .none;
pub const product_name: []const u8 = "afx";
pub const profile_dir_name: []const u8 = ".afx";
pub const project_config_name: []const u8 = ".afx.json";
pub const workspace_skills_dir: []const u8 = ".afx/skills";
pub const workspace_agents_dir: []const u8 = ".afx/agents";
pub const global_agents_dir: []const u8 = ".afx/agents";
pub const is_afx: bool = true;
