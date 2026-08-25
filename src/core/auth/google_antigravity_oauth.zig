const std = @import("std");
const oauth_callback_page = @import("oauth_callback_page.zig");
const google_session = @import("google_cloud_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

const authorization_url = "https://accounts.google.com/o/oauth2/v2/auth";
const token_url = "https://oauth2.googleapis.com/token";
const browser_login_timeout_seconds: i64 = 5 * 60;
const browser_callback_poll_ms: i32 = 100;
const browser_callback_io_timeout_seconds: i64 = 30;
const onboard_timeout_ms: i64 = 30_000;
const onboard_poll_interval_ms: i64 = 1_000;
const free_tier_id = "free-tier";
const antigravity_user_agent = "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)";
const gemini_cli_user_agent = "GeminiCLI/0.46.0/gemini-3.1-pro-preview (darwin; arm64; terminal)";
const gemini_cli_metadata = "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI";

const OAuthKind = enum { antigravity, gemini_cli };
const OAuthConfig = struct {
    kind: OAuthKind,
    client_id: []const u8,
    client_secret: []const u8,
    callback_port: u16,
    callback_path: []const u8,
    scopes: []const u8,
    cloud_code_endpoint: []const u8,
    e2e_authorization_url_env: []const u8,
    e2e_token_url_env: []const u8,
    e2e_cloud_code_url_env: []const u8,
    store: google_session.Store,
};

const antigravity_config = OAuthConfig{
    .kind = .antigravity,
    .client_id = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
    .client_secret = "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",
    .callback_port = 51121,
    .callback_path = "/oauth-callback",
    .scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs",
    .cloud_code_endpoint = "https://daily-cloudcode-pa.googleapis.com",
    .e2e_authorization_url_env = "FX_E2E_GOOGLE_ANTIGRAVITY_AUTH_URL",
    .e2e_token_url_env = "FX_E2E_GOOGLE_ANTIGRAVITY_TOKEN_URL",
    .e2e_cloud_code_url_env = "FX_E2E_GOOGLE_ANTIGRAVITY_CLOUD_CODE_URL",
    .store = google_session.antigravity_store,
};

const gemini_cli_config = OAuthConfig{
    .kind = .gemini_cli,
    .client_id = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
    .client_secret = "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",
    .callback_port = 8085,
    .callback_path = "/oauth2callback",
    .scopes = "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile",
    .cloud_code_endpoint = "https://cloudcode-pa.googleapis.com",
    .e2e_authorization_url_env = "FX_E2E_GOOGLE_GEMINI_CLI_AUTH_URL",
    .e2e_token_url_env = "FX_E2E_GOOGLE_GEMINI_CLI_TOKEN_URL",
    .e2e_cloud_code_url_env = "FX_E2E_GOOGLE_GEMINI_CLI_CLOUD_CODE_URL",
    .store = google_session.gemini_cli_store,
};

pub const RefreshMode = enum { if_needed, force, stored };

pub const Access = struct {
    access_token: []u8,
    project_id: []u8,
    refresh_after_ms: i64,

    pub fn deinit(self: *Access, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        alloc.free(self.project_id);
        self.* = undefined;
    }
};

const BrowserLoginContext = struct {
    listener: std.Io.net.Server,
    redirect_uri: []u8,
    state: []u8,
    transport: oauth_transport.Provider,
    config: *const OAuthConfig,

    fn deinit(self: *BrowserLoginContext, alloc: Allocator) void {
        self.listener.deinit(io_mod.getIo());
        alloc.free(self.redirect_uri);
        secret.zeroAndFree(alloc, self.state);
        self.* = undefined;
    }
};

const PreparedBrowserLogin = struct {
    prepared: login_flow.PreparedLogin,
    context: *BrowserLoginContext,
};

pub fn startSignIn(runtime: *login_flow.SignInRuntime, alloc: Allocator, transport: oauth_transport.Provider) !bool {
    return startConfiguredSignIn(runtime, alloc, transport, &antigravity_config);
}

pub fn startGeminiCliSignIn(runtime: *login_flow.SignInRuntime, alloc: Allocator, transport: oauth_transport.Provider) !bool {
    return startConfiguredSignIn(runtime, alloc, transport, &gemini_cli_config);
}

fn startConfiguredSignIn(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    config: *const OAuthConfig,
) !bool {
    const browser = try prepareBrowserSignIn(alloc, transport, config);
    return runtime.startPrepared(alloc, browser.prepared, .{
        .ctx = browser.context,
        .deinit_ctx = deinitBrowserLoginContext,
        .oauth_transport = transport,
        .poll = .{ .ctx = browser.context, .poll_device_token = pollBrowserToken },
        .complete = completeSignIn,
        .save = saveSignIn,
    });
}

fn prepareBrowserSignIn(alloc: Allocator, transport: oauth_transport.Provider, config: *const OAuthConfig) !PreparedBrowserLogin {
    const auth_endpoint = try configuredEndpoint(alloc, config.e2e_authorization_url_env, authorization_url);
    defer alloc.free(auth_endpoint);
    const token_endpoint = try configuredEndpoint(alloc, config.e2e_token_url_env, token_url);
    errdefer alloc.free(token_endpoint);

    var listener = try bindBrowserCallback(io_mod.getenv(config.e2e_authorization_url_env) != null, config.callback_port);
    var listener_owned = true;
    errdefer if (listener_owned) listener.deinit(io_mod.getIo());
    const port = listener.socket.address.getPort();
    const redirect_uri = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}{s}", .{ port, config.callback_path });
    errdefer alloc.free(redirect_uri);
    const state = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, state);
    const browser_url = try buildAuthorizationUrl(alloc, auth_endpoint, redirect_uri, state, config);
    errdefer alloc.free(browser_url);

    const context = try alloc.create(BrowserLoginContext);
    errdefer alloc.destroy(context);
    context.* = .{
        .listener = listener,
        .redirect_uri = redirect_uri,
        .state = state,
        .transport = transport,
        .config = config,
    };
    listener_owned = false;

    const owned_auth_endpoint = try alloc.dupe(u8, auth_endpoint);
    errdefer alloc.free(owned_auth_endpoint);
    const device_code = try alloc.dupe(u8, "");
    errdefer secret.zeroAndFree(alloc, device_code);
    const user_code = try alloc.dupe(u8, "");
    errdefer alloc.free(user_code);
    const owned_client_id = try alloc.dupe(u8, config.client_id);
    errdefer alloc.free(owned_client_id);

    return .{
        .prepared = .{
            .metadata = .{
                .issuer = owned_auth_endpoint,
                .device_authorization_endpoint = try alloc.dupe(u8, auth_endpoint),
                .token_endpoint = token_endpoint,
            },
            .device = .{
                .device_code = device_code,
                .user_code = user_code,
                .verification_uri = browser_url,
                .expires_in = browser_login_timeout_seconds,
                .interval = 1,
            },
            .client_id = owned_client_id,
        },
        .context = context,
    };
}

fn deinitBrowserLoginContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    context.deinit(alloc);
    alloc.destroy(context);
}

fn bindBrowserCallback(e2e: bool, port: u16) !std.Io.net.Server {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", if (e2e) 0 else port);
    return address.listen(io_mod.getIo(), .{ .reuse_address = true });
}

fn randomUrlSafeSecret(alloc: Allocator) ![]u8 {
    var entropy: [32]u8 = undefined;
    try io_mod.getIo().randomSecure(&entropy);
    const encoded = try alloc.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(entropy.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &entropy);
    return encoded;
}

fn pollBrowserToken(
    raw: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    _: []const u8,
    _: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (comptime host_target.is_wasm) return error.GoogleOAuthUnavailable;
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    if (!try browserCallbackReady(&context.listener, cancel_flag)) return .pending;

    var stream = try context.listener.accept(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    setBrowserSocketTimeouts(stream.socket.handle);
    const target = try readBrowserCallbackTarget(alloc, stream);
    defer alloc.free(target);
    var callback = parseBrowserCallbackTarget(alloc, target, context.state, context.config.callback_path) catch |err| {
        writeBrowserCallbackResponse(stream, false) catch {};
        return err;
    };
    defer callback.deinit(alloc);

    var token = exchangeAuthorizationCode(
        alloc,
        transport,
        metadata.token_endpoint,
        callback.code,
        context.redirect_uri,
        cancel_flag,
        deadline,
        context.config,
    ) catch |err| {
        writeBrowserCallbackResponse(stream, false) catch {};
        return err;
    };
    errdefer token.deinit(alloc);
    try writeBrowserCallbackResponse(stream, true);
    return .{ .success = token };
}

fn completeSignIn(
    raw: ?*anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    token: *oauth.TokenSet,
) !login_flow.SignInCompletion {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    const refresh_token = token.refresh_token orelse return error.GoogleRefreshTokenMissing;
    const project_id = switch (context.config.kind) {
        .antigravity => try discoverProject(alloc, context.transport, token.access_token),
        .gemini_cli => try discoverGeminiCliProject(alloc, context.transport, token.access_token, context.config),
    };
    errdefer alloc.free(project_id);
    const expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), token.expires_in);
    const session = google_session.Session{
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .project_id = project_id,
    };
    const completion: login_flow.SignInCompletion = switch (context.config.kind) {
        .antigravity => .{ .google_antigravity = session },
        .gemini_cli => .{ .google_gemini_cli = session },
    };
    token.access_token = &.{};
    token.refresh_token = null;
    return completion;
}

fn saveSignIn(raw: ?*anyopaque, alloc: Allocator, completion: login_flow.SignInCompletion) !void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    const session = switch (completion) {
        .google_antigravity => |session| session,
        .google_gemini_cli => |session| session,
        .vercel, .chatgpt, .grok => return error.InvalidSignInCompletion,
    };
    try google_session.saveNewSession(context.config.store, alloc, session);
}

pub fn runLogin(alloc: Allocator, transport: oauth_transport.Provider, url_opener: host.UrlOpener) !void {
    return runConfiguredLogin(alloc, transport, url_opener, &antigravity_config, "Google Antigravity");
}

pub fn runGeminiCliLogin(alloc: Allocator, transport: oauth_transport.Provider, url_opener: host.UrlOpener) !void {
    return runConfiguredLogin(alloc, transport, url_opener, &gemini_cli_config, "Google Gemini CLI");
}

fn runConfiguredLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
    config: *const OAuthConfig,
    name: []const u8,
) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startConfiguredSignIn(&runtime, alloc, transport, config)) return error.GoogleLoginBusy;
    const browser_url = (try runtime.browserUrlAlloc(alloc)) orelse return error.GoogleAuthorizationUrlMissing;
    defer alloc.free(browser_url);
    const prefix = try std.fmt.allocPrint(alloc, "Open this URL to sign in with {s}:\n", .{name});
    defer alloc.free(prefix);
    try writeStdout(prefix);
    try writeStdout(browser_url);
    try writeStdout("\n\nWaiting for browser authorization...\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) _ = url_opener.open(alloc, browser_url) catch false;
    while (true) switch (runtime.pollTransition(alloc)) {
        .none => try io_mod.getIo().sleep(.fromMilliseconds(50), .awake),
        .succeeded => |completion| {
            var owned = completion;
            defer owned.deinit(alloc);
            return;
        },
        .failed => |err| return err,
        .cancelled => return error.Cancelled,
    };
}

pub fn logout() !google_session.DeleteOutcome {
    return logoutConfigured(antigravity_config.store);
}

pub fn logoutGeminiCli() !google_session.DeleteOutcome {
    return logoutConfigured(gemini_cli_config.store);
}

fn logoutConfigured(store: google_session.Store) !google_session.DeleteOutcome {
    var mutation = (try google_session.beginExistingMutation(store)) orelse return .missing;
    defer mutation.deinit();
    return mutation.delete();
}

pub fn sourceExists(alloc: Allocator) !bool {
    return sourceExistsConfigured(alloc, antigravity_config.store);
}

pub fn sourceExistsGeminiCli(alloc: Allocator) !bool {
    return sourceExistsConfigured(alloc, gemini_cli_config.store);
}

fn sourceExistsConfigured(alloc: Allocator, store: google_session.Store) !bool {
    var session = (try google_session.load(store, alloc)) orelse return false;
    defer session.deinit(alloc);
    return true;
}

pub fn loadAccess(alloc: Allocator, transport: oauth_transport.Provider, mode: RefreshMode) !?Access {
    return loadConfiguredAccess(alloc, transport, mode, &antigravity_config);
}

pub fn loadGeminiCliAccess(alloc: Allocator, transport: oauth_transport.Provider, mode: RefreshMode) !?Access {
    return loadConfiguredAccess(alloc, transport, mode, &gemini_cli_config);
}

fn loadConfiguredAccess(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
    config: *const OAuthConfig,
) !?Access {
    if (mode == .stored) {
        var session = (try google_session.load(config.store, alloc)) orelse return null;
        defer session.deinit(alloc);
        return takeAccess(&session);
    }
    var mutation = (try google_session.beginExistingMutation(config.store)) orelse return null;
    defer mutation.deinit();
    var session = (try mutation.load(alloc)) orelse return null;
    defer session.deinit(alloc);
    if (mode == .force or session.expired(io_mod.milliTimestamp())) {
        try refreshSession(alloc, transport, &mutation, &session, config);
    }
    return takeAccess(&session);
}

fn takeAccess(session: *google_session.Session) Access {
    const access_token = session.access_token;
    session.access_token = &.{};
    const project_id = session.project_id;
    session.project_id = &.{};
    return .{
        .access_token = access_token,
        .project_id = project_id,
        .refresh_after_ms = google_session.refreshDeadlineMs(session.expires_at_ms),
    };
}

fn refreshSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mutation: *google_session.Mutation,
    session: *google_session.Session,
    config: *const OAuthConfig,
) !void {
    var form_out: std.Io.Writer.Allocating = .init(alloc);
    defer form_out.deinit();
    var form: FormBody = .{};
    try form.append(&form_out.writer, "client_id", config.client_id);
    try form.append(&form_out.writer, "client_secret", config.client_secret);
    try form.append(&form_out.writer, "refresh_token", session.refresh_token);
    try form.append(&form_out.writer, "grant_type", "refresh_token");
    var token = try requestToken(alloc, transport, form_out.written(), null, null, config);
    defer token.deinit(alloc);
    const refresh_token = if (token.refresh_token) |rotated| rotated else try alloc.dupe(u8, session.refresh_token);
    if (token.refresh_token != null) token.refresh_token = null;
    errdefer secret.zeroAndFree(alloc, refresh_token);
    var replacement = google_session.Session{
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), token.expires_in),
        .project_id = try alloc.dupe(u8, session.project_id),
    };
    token.access_token = &.{};
    errdefer replacement.deinit(alloc);
    try mutation.save(alloc, replacement);
    session.deinit(alloc);
    session.* = replacement;
    replacement.access_token = &.{};
    replacement.refresh_token = &.{};
    replacement.project_id = &.{};
}

fn exchangeAuthorizationCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    config: *const OAuthConfig,
) !oauth.TokenSet {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var form: FormBody = .{};
    try form.append(&out.writer, "client_id", config.client_id);
    try form.append(&out.writer, "client_secret", config.client_secret);
    try form.append(&out.writer, "code", code);
    try form.append(&out.writer, "grant_type", "authorization_code");
    try form.append(&out.writer, "redirect_uri", redirect_uri);
    return requestTokenAt(alloc, transport, endpoint, out.written(), cancel_flag, deadline);
}

fn requestToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    config: *const OAuthConfig,
) !oauth.TokenSet {
    const endpoint = try configuredEndpoint(alloc, config.e2e_token_url_env, token_url);
    defer alloc.free(endpoint);
    return requestTokenAt(alloc, transport, endpoint, payload, cancel_flag, deadline);
}

fn requestTokenAt(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint: []const u8,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !oauth.TokenSet {
    const bytes = try requestAccepted(alloc, transport, .post_form, endpoint, payload, null, cancel_flag, deadline);
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGoogleAntigravityOAuthResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = if (object.get("refresh_token")) |value| token: {
        if (value != .string or value.string.len == 0) return error.InvalidGoogleAntigravityOAuthResponse;
        break :token try alloc.dupe(u8, value.string);
    } else null;
    errdefer if (refresh_token) |value| secret.zeroAndFree(alloc, value);
    const scope = if (object.get("scope")) |value|
        if (value == .string) try alloc.dupe(u8, value.string) else try alloc.dupe(u8, "")
    else
        try alloc.dupe(u8, "");
    errdefer if (scope.len > 0) alloc.free(scope);
    const token_type = if (object.get("token_type")) |value|
        if (value == .string) try alloc.dupe(u8, value.string) else try alloc.dupe(u8, "Bearer")
    else
        try alloc.dupe(u8, "Bearer");
    errdefer alloc.free(token_type);
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = try requiredPositiveInteger(object, "expires_in"),
        .scope = scope,
        .token_type = token_type,
    };
}

fn discoverProject(alloc: Allocator, transport: oauth_transport.Provider, access_token: []const u8) ![]u8 {
    const endpoint = try configuredEndpoint(alloc, antigravity_config.e2e_cloud_code_url_env, antigravity_config.cloud_code_endpoint);
    defer alloc.free(endpoint);
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    defer secret.zeroAndFree(alloc, auth);

    var initial = try loadCodeAssist(alloc, transport, endpoint, auth, null);
    defer initial.deinit(alloc);
    try assertFreeTierEligible(initial.value);
    if (!hasObjectField(initial.value, "currentTier")) {
        try onboardUser(alloc, transport, endpoint, auth);
    }
    var refreshed = try loadCodeAssist(alloc, transport, endpoint, auth, initial.projectId());
    defer refreshed.deinit(alloc);
    return refreshed.takeProjectId() orelse error.GoogleAntigravityProjectMissing;
}

fn discoverGeminiCliProject(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    access_token: []const u8,
    config: *const OAuthConfig,
) ![]u8 {
    const endpoint = try configuredEndpoint(alloc, config.e2e_cloud_code_url_env, config.cloud_code_endpoint);
    defer alloc.free(endpoint);
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    defer secret.zeroAndFree(alloc, authorization);
    const env_project = io_mod.getenv("GOOGLE_CLOUD_PROJECT") orelse io_mod.getenv("GOOGLE_CLOUD_PROJECT_ID");
    const load_url = try std.fmt.allocPrint(alloc, "{s}/v1internal:loadCodeAssist", .{std.mem.trimEnd(u8, endpoint, "/")});
    defer alloc.free(load_url);
    var load_body: std.Io.Writer.Allocating = .init(alloc);
    defer load_body.deinit();
    try load_body.writer.writeByte('{');
    if (env_project) |project| {
        try load_body.writer.writeAll("\"cloudaicompanionProject\":");
        try std.json.Stringify.value(project, .{}, &load_body.writer);
        try load_body.writer.writeByte(',');
    }
    try load_body.writer.writeAll("\"metadata\":{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"");
    if (env_project) |project| {
        try load_body.writer.writeAll(",\"duetProject\":");
        try std.json.Stringify.value(project, .{}, &load_body.writer);
    }
    try load_body.writer.writeAll("}}");
    const loaded_bytes = try requestGeminiCliAccepted(
        alloc,
        transport,
        .post_json,
        load_url,
        load_body.written(),
        authorization,
    );
    defer secret.zeroAndFree(alloc, loaded_bytes);
    var loaded = try std.json.parseFromSlice(std.json.Value, alloc, loaded_bytes, .{});
    defer loaded.deinit();
    if (loaded.value != .object) return error.InvalidGoogleGeminiCliProvisioningResponse;
    if (stringField(loaded.value, "cloudaicompanionProject")) |project| return alloc.dupe(u8, project);
    if (loaded.value.object.get("currentTier") != null) {
        return alloc.dupe(u8, env_project orelse return error.GoogleGeminiCliProjectRequired);
    }

    const tier_id = defaultGeminiCliTier(loaded.value.object);
    if (!std.mem.eql(u8, tier_id, free_tier_id) and env_project == null) {
        return error.GoogleGeminiCliProjectRequired;
    }
    const onboard_url = try std.fmt.allocPrint(alloc, "{s}/v1internal:onboardUser", .{std.mem.trimEnd(u8, endpoint, "/")});
    defer alloc.free(onboard_url);
    var onboard_body: std.Io.Writer.Allocating = .init(alloc);
    defer onboard_body.deinit();
    try onboard_body.writer.writeAll("{\"tierId\":");
    try std.json.Stringify.value(tier_id, .{}, &onboard_body.writer);
    if (env_project) |project| {
        try onboard_body.writer.writeAll(",\"cloudaicompanionProject\":");
        try std.json.Stringify.value(project, .{}, &onboard_body.writer);
    }
    try onboard_body.writer.writeAll(",\"metadata\":{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"");
    if (env_project) |project| {
        try onboard_body.writer.writeAll(",\"duetProject\":");
        try std.json.Stringify.value(project, .{}, &onboard_body.writer);
    }
    try onboard_body.writer.writeAll("}}");
    const onboard_bytes = try requestGeminiCliAccepted(
        alloc,
        transport,
        .post_json,
        onboard_url,
        onboard_body.written(),
        authorization,
    );
    defer secret.zeroAndFree(alloc, onboard_bytes);
    var operation = try std.json.parseFromSlice(std.json.Value, alloc, onboard_bytes, .{});
    defer operation.deinit();
    for (0..24) |attempt| {
        if (geminiCliOperationProject(operation.value)) |project| return alloc.dupe(u8, project);
        const name = stringField(operation.value, "name") orelse break;
        if (attempt > 0) try io_mod.getIo().sleep(.fromSeconds(5), .awake);
        const poll_url = try std.fmt.allocPrint(alloc, "{s}/v1internal/{s}", .{ std.mem.trimEnd(u8, endpoint, "/"), name });
        defer alloc.free(poll_url);
        const poll_bytes = try requestGeminiCliAccepted(alloc, transport, .get, poll_url, "", authorization);
        defer secret.zeroAndFree(alloc, poll_bytes);
        operation.deinit();
        operation = try std.json.parseFromSlice(std.json.Value, alloc, poll_bytes, .{});
    }
    if (env_project) |project| return alloc.dupe(u8, project);
    return error.GoogleGeminiCliProjectMissing;
}

fn defaultGeminiCliTier(object: std.json.ObjectMap) []const u8 {
    const tiers = object.get("allowedTiers") orelse return "legacy-tier";
    if (tiers != .array) return "legacy-tier";
    for (tiers.array.items) |tier| {
        if (tier != .object) continue;
        const is_default = tier.object.get("isDefault") orelse continue;
        if (is_default != .bool or !is_default.bool) continue;
        return stringField(tier, "id") orelse "legacy-tier";
    }
    return "legacy-tier";
}

fn geminiCliOperationProject(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const done = value.object.get("done") orelse return null;
    if (done != .bool or !done.bool) return null;
    const response = value.object.get("response") orelse return null;
    if (response != .object) return null;
    const project = response.object.get("cloudaicompanionProject") orelse return null;
    if (project == .string) return project.string;
    return stringField(project, "id");
}

fn requestGeminiCliAccepted(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    method: oauth_transport.Method,
    url: []const u8,
    payload: []const u8,
    authorization: []const u8,
) ![]u8 {
    var response = try transport.execute(alloc, .{
        .method = method,
        .url = url,
        .payload = if (payload.len > 0) payload else null,
        .authorization = authorization,
        .user_agent = gemini_cli_user_agent,
        .client_metadata = gemini_cli_metadata,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.GoogleGeminiCliRequestFailed;
    return response.takeBody();
}

const LoadedCodeAssist = struct {
    value: std.json.Parsed(std.json.Value),
    owned_project_id: ?[]u8 = null,

    fn deinit(self: *LoadedCodeAssist, alloc: Allocator) void {
        if (self.owned_project_id) |project| alloc.free(project);
        self.value.deinit();
        self.* = undefined;
    }

    fn projectId(self: *const LoadedCodeAssist) ?[]const u8 {
        return stringField(self.value.value, "cloudaicompanionProject");
    }

    fn takeProjectId(self: *LoadedCodeAssist) ?[]u8 {
        const project = self.owned_project_id;
        self.owned_project_id = null;
        return project;
    }
};

fn loadCodeAssist(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint: []const u8,
    authorization: []const u8,
    project_id: ?[]const u8,
) !LoadedCodeAssist {
    const url = try std.fmt.allocPrint(alloc, "{s}/v1internal:loadCodeAssist", .{std.mem.trimEnd(u8, endpoint, "/")});
    defer alloc.free(url);
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    try body.writer.writeByte('{');
    if (project_id) |project| {
        try body.writer.writeAll("\"cloudaicompanionProject\":");
        try std.json.Stringify.value(project, .{}, &body.writer);
        try body.writer.writeByte(',');
    }
    try body.writer.writeAll("\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}");
    const bytes = try requestAccepted(alloc, transport, .post_json, url, body.written(), authorization, null, null);
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGoogleAntigravityProvisioningResponse;
    const project = if (stringField(parsed.value, "cloudaicompanionProject")) |value| try alloc.dupe(u8, value) else null;
    return .{ .value = parsed, .owned_project_id = project };
}

fn assertFreeTierEligible(parsed: std.json.Parsed(std.json.Value)) !void {
    const root = parsed.value;
    if (root != .object) return error.InvalidGoogleAntigravityProvisioningResponse;
    const tiers = root.object.get("ineligibleTiers") orelse return;
    if (tiers != .array) return;
    for (tiers.array.items) |tier| {
        if (tier != .object) continue;
        const tier_id = stringField(tier, "tierId") orelse continue;
        if (!std.mem.eql(u8, tier_id, free_tier_id)) continue;
        return error.GoogleAntigravityFreeTierUnavailable;
    }
}

fn onboardUser(alloc: Allocator, transport: oauth_transport.Provider, endpoint: []const u8, authorization: []const u8) !void {
    const url = try std.fmt.allocPrint(alloc, "{s}/v1internal:onboardUser", .{std.mem.trimEnd(u8, endpoint, "/")});
    defer alloc.free(url);
    const payload = "{\"tierId\":\"free-tier\",\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}";
    const bytes = try requestAccepted(alloc, transport, .post_json, url, payload, authorization, null, null);
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const deadline = io_mod.milliTimestamp() + onboard_timeout_ms;
    while (true) {
        if (try operationDone(parsed.value)) return;
        if (io_mod.milliTimestamp() >= deadline) return error.GoogleAntigravityOnboardingTimeout;
        const name = stringField(parsed.value, "name") orelse return error.InvalidGoogleAntigravityProvisioningResponse;
        try io_mod.getIo().sleep(.fromMilliseconds(onboard_poll_interval_ms), .awake);
        const operation_url = try std.fmt.allocPrint(alloc, "{s}/v1internal/{s}", .{ std.mem.trimEnd(u8, endpoint, "/"), name });
        defer alloc.free(operation_url);
        const next = try requestAccepted(alloc, transport, .get, operation_url, "", authorization, null, null);
        defer secret.zeroAndFree(alloc, next);
        parsed.deinit();
        parsed = try std.json.parseFromSlice(std.json.Value, alloc, next, .{});
    }
}

fn operationDone(value: std.json.Value) !bool {
    if (value != .object) return error.InvalidGoogleAntigravityProvisioningResponse;
    const done = value.object.get("done") orelse return false;
    if (done != .bool or !done.bool) return false;
    if (value.object.get("error")) |failure| if (failure != .null) return error.GoogleAntigravityOnboardingFailed;
    const response = value.object.get("response") orelse return error.InvalidGoogleAntigravityProvisioningResponse;
    if (response != .object) return error.InvalidGoogleAntigravityProvisioningResponse;
    return true;
}

fn requestAccepted(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    method: oauth_transport.Method,
    url: []const u8,
    payload: []const u8,
    authorization: ?[]const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) ![]u8 {
    if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    var response = try transport.execute(alloc, .{
        .method = method,
        .url = url,
        .payload = if (payload.len > 0) payload else null,
        .authorization = authorization,
        .user_agent = antigravity_user_agent,
        .cancel_flag = cancel_flag,
        .deadline = deadline,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        debug_trace.logf("auth", "Antigravity OAuth request rejected url={s}", .{url});
        return error.GoogleAntigravityOAuthRequestFailed;
    }
    return response.takeBody();
}

fn configuredEndpoint(alloc: Allocator, env_name: []const u8, fallback: []const u8) ![]u8 {
    const override = io_mod.getenv(env_name) orelse return alloc.dupe(u8, fallback);
    if (!isLoopbackHttpUrl(override)) return error.InvalidGoogleAntigravityE2EEndpoint;
    return alloc.dupe(u8, override);
}

fn isLoopbackHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://127.0.0.1:") or std.mem.startsWith(u8, url, "http://localhost:");
}

fn hasObjectField(parsed: std.json.Parsed(std.json.Value), key: []const u8) bool {
    return parsed.value == .object and parsed.value.object.get(key) != null;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string and field.string.len > 0) field.string else null;
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidGoogleAntigravityOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidGoogleAntigravityOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn requiredPositiveInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidGoogleAntigravityOAuthResponse;
    if (value != .integer or value.integer <= 0) return error.InvalidGoogleAntigravityOAuthResponse;
    return value.integer;
}

const BrowserCallback = struct {
    code: []u8,
    fn deinit(self: *BrowserCallback, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        self.* = undefined;
    }
};

fn buildAuthorizationUrl(
    alloc: Allocator,
    endpoint: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    config: *const OAuthConfig,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s}?", .{endpoint});
    var form: FormBody = .{};
    try form.append(&out.writer, "client_id", config.client_id);
    try form.append(&out.writer, "response_type", "code");
    try form.append(&out.writer, "redirect_uri", redirect_uri);
    try form.append(&out.writer, "scope", config.scopes);
    try form.append(&out.writer, "state", state);
    try form.append(&out.writer, "access_type", "offline");
    try form.append(&out.writer, "prompt", "consent");
    return out.toOwnedSlice();
}

fn parseBrowserCallbackTarget(alloc: Allocator, target: []const u8, expected_state: []const u8, callback_path: []const u8) !BrowserCallback {
    const prefix = try std.fmt.allocPrint(alloc, "{s}?", .{callback_path});
    defer alloc.free(prefix);
    if (!std.mem.startsWith(u8, target, prefix) or std.mem.findScalar(u8, target, '#') != null) return error.InvalidGoogleAntigravityOAuthCallback;
    const query = target[prefix.len..];
    const code = try queryValueAlloc(alloc, query, "code");
    errdefer secret.zeroAndFree(alloc, code);
    const state = try queryValueAlloc(alloc, query, "state");
    defer secret.zeroAndFree(alloc, state);
    if (!std.mem.eql(u8, state, expected_state)) return error.GoogleAntigravityOAuthStateMismatch;
    return .{ .code = code };
}

fn queryValueAlloc(alloc: Allocator, query: []const u8, key: []const u8) ![]u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], key)) return percentDecodeAlloc(alloc, pair[equals + 1 ..]);
    }
    return error.InvalidGoogleAntigravityOAuthCallback;
}

fn percentDecodeAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, value.len);
    errdefer alloc.free(out);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < value.len) {
        if (value[read_index] == '%') {
            if (read_index + 2 >= value.len) return error.InvalidGoogleAntigravityOAuthCallback;
            const high = std.fmt.charToDigit(value[read_index + 1], 16) catch return error.InvalidGoogleAntigravityOAuthCallback;
            const low = std.fmt.charToDigit(value[read_index + 2], 16) catch return error.InvalidGoogleAntigravityOAuthCallback;
            out[write_index] = @intCast(high * 16 + low);
            read_index += 3;
        } else {
            out[write_index] = if (value[read_index] == '+') ' ' else value[read_index];
            read_index += 1;
        }
        write_index += 1;
    }
    if (write_index == 0) return error.InvalidGoogleAntigravityOAuthCallback;
    return alloc.realloc(out, write_index);
}

fn browserCallbackReady(listener: *std.Io.net.Server, cancel_flag: *std.atomic.Value(bool)) !bool {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = try std.posix.poll(&fds, browser_callback_poll_ms);
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (ready == 0) return false;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) return error.InvalidGoogleAntigravityOAuthCallback;
    return true;
}

fn readBrowserCallbackTarget(alloc: Allocator, stream: std.Io.net.Stream) ![]u8 {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request_bytes.len) {
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.InvalidGoogleAntigravityOAuthCallback,
            else => return err,
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) break;
    }
    if (request_len == request_bytes.len) return error.GoogleAntigravityOAuthCallbackTooLarge;
    const line_end = std.mem.find(u8, request_bytes[0..request_len], "\r\n") orelse return error.InvalidGoogleAntigravityOAuthCallback;
    const request_line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, request_line, "GET ")) return error.InvalidGoogleAntigravityOAuthCallback;
    const target_end = std.mem.findScalarPos(u8, request_line, 4, ' ') orelse return error.InvalidGoogleAntigravityOAuthCallback;
    return alloc.dupe(u8, request_line[4..target_end]);
}

fn writeBrowserCallbackResponse(stream: std.Io.net.Stream, success: bool) !void {
    var body_buffer: [128]u8 = undefined;
    const body = try oauth_callback_page.body(&body_buffer, success);
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print(
        "HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ if (success) "200 OK" else "400 Bad Request", body.len, body },
    );
    try writer.interface.flush();
}

fn setBrowserSocketTimeouts(socket: std.posix.socket_t) void {
    const timeout = std.posix.timeval{ .sec = browser_callback_io_timeout_seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

const FormBody = struct {
    first: bool = true,
    fn append(self: *FormBody, writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
        if (!self.first) try writer.writeByte('&');
        self.first = false;
        try percentEncode(writer, key);
        try writer.writeByte('=');
        try percentEncode(writer, value);
    }
};

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (safe) {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

test "Antigravity authorization URL mirrors OMP scopes" {
    const url = try buildAuthorizationUrl(
        std.testing.allocator,
        "https://accounts.google.com/o/oauth2/v2/auth",
        "http://127.0.0.1:51121/oauth-callback",
        "state",
        &antigravity_config,
    );
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.find(u8, url, "access_type=offline") != null);
    try std.testing.expect(std.mem.find(u8, url, "prompt=consent") != null);
    try std.testing.expect(std.mem.find(u8, url, "cloud-platform") != null);
}
