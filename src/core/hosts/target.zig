const builtin = @import("builtin");

pub const is_wasm = builtin.os.tag == .wasi;
