const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const communication = @import("communication.zig");
const communication_store = @import("communication_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_store = @import("../session/session_store.zig");
const work_events = @import("work_events.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const max_ancestry_depth: usize = 1024;

pub const Error = error{
    OutOfMemory,
    ChildNotAttached,
    RelationshipCycle,
    GraphTooDeep,
    InvalidRequest,
    RequestConflict,
    RequestResolved,
    LockBusy,
    LockUnsupported,
    StoreUnavailable,
    CommitIndeterminate,
    CapacityExceeded,
};

pub const RelationshipContinuation = struct {
    child_id: []u8,
    root_id: []u8,
    action: domain.RelationshipAction,
    prospective_parent_id: []u8,
    operation_id: []u8,
    status: communication.ApprovalStatus,

    pub fn deinit(self: *RelationshipContinuation, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        alloc.free(self.prospective_parent_id);
        alloc.free(self.operation_id);
        self.* = undefined;
    }
};

pub const DurableRegistry = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    child_store_options: session_child_store.Options = .{},

    pub fn interface(self: *DurableRegistry) approval_registry.Persistence {
        return .{
            .context = self,
            .register_fn = registerCallback,
            .commit_response_fn = commitCallback,
            .invalidate_fn = invalidateCallback,
        };
    }

    fn registerCallback(
        raw: ?*anyopaque,
        input: communication.ApprovalInput,
    ) approval_registry.PersistenceError!void {
        const self: *DurableRegistry = @ptrCast(@alignCast(raw.?));
        self.register(input) catch |err| return mapPersistence(err);
    }

    fn commitCallback(
        raw: ?*anyopaque,
        response: communication.ApprovalResponse,
        identity_fingerprint: [32]u8,
    ) approval_registry.PersistenceError!void {
        const self: *DurableRegistry = @ptrCast(@alignCast(raw.?));
        self.commitResponse(response, identity_fingerprint) catch |err|
            return mapPersistence(err);
    }

    fn invalidateCallback(
        raw: ?*anyopaque,
        request_id: []const u8,
        child_id: []const u8,
        status: communication.ApprovalStatus,
        timestamp_ms: i64,
    ) approval_registry.PersistenceError!void {
        const self: *DurableRegistry = @ptrCast(@alignCast(raw.?));
        self.invalidate(request_id, child_id, status, timestamp_ms) catch |err|
            return mapPersistence(err);
    }

    fn register(
        self: *DurableRegistry,
        input: communication.ApprovalInput,
    ) Error!void {
        var chain = if (input.relationship) |relationship|
            try LockedChain.acquireRelationship(
                self.alloc,
                self.sessions,
                input.child_id,
                relationship.prospective_parent_id,
                self.child_store_options,
            )
        else
            try LockedChain.acquire(
                self.alloc,
                self.sessions,
                input.child_id,
                self.child_store_options,
            );
        defer chain.deinit(self.alloc);
        if (input.relationship) |relationship| {
            try chain.validate(relationship.prospective_parent_id, input.root_id);
        } else {
            try chain.validate(input.child_id, input.root_id);
        }
        const child = chain.find(input.child_id) orelse return error.ChildNotAttached;
        var control = control_store.Store{
            .capability = &child.capability,
            .expected_child_id = input.child_id,
        };
        var maybe_record = control.loadOptional(self.alloc) catch |err| return mapControl(err);
        defer if (maybe_record) |*record| record.deinit(self.alloc);
        if (maybe_record) |record| if (record.state == .archived or
            record.state == .cancelled or record.state == .completed or
            record.state == .failed)
        {
            return error.InvalidRequest;
        };
        switch (input.kind) {
            .tool => {
                const record = maybe_record orelse return error.InvalidRequest;
                if (record.parent_id == null) return error.InvalidRequest;
                const work_id = input.work_id orelse return error.InvalidRequest;
                if (!workIsActive(record.queue, work_id)) return error.InvalidRequest;
            },
            .relationship => if (input.work_id != null or
                input.relationship == null or input.grants.len != 0)
            {
                return error.InvalidRequest;
            },
        }
        const store = communication_store.Store{
            .capability = &child.capability,
            .expected_session_id = input.child_id,
        };
        var ledger = try loadOrInit(self.alloc, store, input.child_id);
        defer ledger.deinit(self.alloc);
        _ = communication.registerApproval(self.alloc, &ledger, input) catch |err|
            return mapMutation(err);
        const stored_approval = communication.findApproval(
            ledger.approvals,
            input.id,
        ) orelse return error.InvalidRequest;
        _ = communication.appendDelivery(self.alloc, &ledger, .{
            .id = stored_approval.id,
            .source_id = stored_approval.child_id,
            .target_id = stored_approval.root_id,
            .work_id = stored_approval.work_id,
            .operation_id = stored_approval.id,
            .operation_identity_admitted = input.operation_identity_admitted,
            .timestamp_ms = stored_approval.created_at_ms,
            .payload = .{ .approval = stored_approval.label },
        }) catch |err| return mapMutation(err);
        save(store, self.alloc, ledger) catch |err| {
            if (err != error.CommitIndeterminate) return err;
            var observed = store.load(self.alloc) catch return error.CommitIndeterminate;
            defer observed.deinit(self.alloc);
            const approval = communication.findApproval(
                observed.approvals,
                input.id,
            ) orelse return error.CommitIndeterminate;
            if (!std.mem.eql(
                u8,
                &approval.identity_fingerprint,
                &communication.approvalIdentityFingerprint(input),
            )) {
                return error.CommitIndeterminate;
            }
        };
    }

    fn commitResponse(
        self: *DurableRegistry,
        response: communication.ApprovalResponse,
        identity_fingerprint: [32]u8,
    ) Error!void {
        const routing = try self.loadApprovalRouting(
            response.child_id,
            response.request_id,
        );
        defer if (routing.prospective_parent_id) |value| self.alloc.free(value);
        var chain = if (routing.prospective_parent_id) |parent_id|
            try LockedChain.acquireRelationship(
                self.alloc,
                self.sessions,
                response.child_id,
                parent_id,
                self.child_store_options,
            )
        else
            try LockedChain.acquire(
                self.alloc,
                self.sessions,
                response.child_id,
                self.child_store_options,
            );
        defer chain.deinit(self.alloc);
        const child = chain.find(response.child_id) orelse
            return error.ChildNotAttached;
        var child_control = control_store.Store{
            .capability = &child.capability,
            .expected_child_id = response.child_id,
        };
        var maybe_record = child_control.loadOptional(self.alloc) catch |err| return mapControl(err);
        defer if (maybe_record) |*record| record.deinit(self.alloc);
        var child_store = communication_store.Store{
            .capability = &child.capability,
            .expected_session_id = response.child_id,
        };
        var child_ledger = child_store.load(self.alloc) catch |err| return mapLoad(err);
        defer child_ledger.deinit(self.alloc);
        const approval = communication.findApproval(
            child_ledger.approvals,
            response.request_id,
        ) orelse return error.InvalidRequest;
        if (!std.mem.eql(
            u8,
            &approval.identity_fingerprint,
            &identity_fingerprint,
        )) return error.RequestConflict;
        if (approval.relationship) |relationship| {
            try chain.validate(relationship.prospective_parent_id, approval.root_id);
        } else {
            try chain.validate(response.child_id, approval.root_id);
        }
        const work_valid = if (approval.work_id) |work_id|
            if (maybe_record) |record| workIsActive(record.queue, work_id) else false
        else
            true;
        const attachment_valid = approval.kind == .relationship or
            (maybe_record != null and maybe_record.?.parent_id != null);
        if (!work_valid or (if (maybe_record) |record|
            record.state == .cancelled or record.state == .archived
        else
            approval.kind != .relationship) or !attachment_valid)
        {
            return error.RequestResolved;
        }
        const replay = approvalResponseMatches(approval.*, response);
        const decision = if (approval.status == .pending)
            communication.decideApprovalResponse(
                approval.*,
                response,
                .{
                    .attached = true,
                    .child_cancelled = false,
                    .child_closed = false,
                },
            )
        else if (replay)
            null
        else
            return error.RequestResolved;
        if (decision) |value| if (value == .reject) return error.RequestResolved;
        if (decision != null and decision.? == .accept_always) {
            const root = chain.find(approval.root_id) orelse
                return error.ChildNotAttached;
            const root_store = communication_store.Store{
                .capability = &root.capability,
                .expected_session_id = approval.root_id,
            };
            var root_ledger = try loadOrInit(
                self.alloc,
                root_store,
                approval.root_id,
            );
            defer root_ledger.deinit(self.alloc);
            _ = communication.applyAlwaysGrants(
                self.alloc,
                &root_ledger,
                approval.grants,
            ) catch |err| return mapMutation(err);
            try save(root_store, self.alloc, root_ledger);
            debug_trace.logf(
                "subagent",
                "approval grant committed request_id={s} child_id={s} outcome=grant_before_wake",
                .{ response.request_id, response.child_id },
            );
        }
        if (decision) |value| {
            const revision = std.math.add(u64, child_ledger.generation, 1) catch
                return error.InvalidRequest;
            communication.applyApprovalDecision(
                approval,
                value,
                response.timestamp_ms,
                revision,
            ) catch |err| return mapMutation(err);
            child_ledger.generation = revision;
            try save(child_store, self.alloc, child_ledger);
            debug_trace.logf(
                "subagent",
                "approval response committed request_id={s} child_id={s} outcome={s}",
                .{ response.request_id, response.child_id, @tagName(response.decision) },
            );
        }
        if (approval.work_id) |work_id| {
            const record = if (maybe_record) |*value| value else return error.InvalidRequest;
            const transition = work_events.resumeApproval(
                self.alloc,
                record,
                work_id,
                response.timestamp_ms,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.GenerationExhausted => error.InvalidRequest,
            };
            switch (transition) {
                .changed => child_control.save(self.alloc, record.*) catch |err|
                    return mapControlSave(err),
                .already_in_state => {},
                .cancellation_won, .stale_work => return error.RequestResolved,
            }
        }
    }

    pub fn loadRelationshipContinuation(
        self: *DurableRegistry,
        child_id: []const u8,
        request_id: []const u8,
    ) Error!RelationshipContinuation {
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            self.alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var ledger = store.load(self.alloc) catch |err| return mapLoad(err);
        defer ledger.deinit(self.alloc);
        const approval = communication.findApproval(
            ledger.approvals,
            request_id,
        ) orelse return error.InvalidRequest;
        if (approval.kind != .relationship or
            !std.mem.eql(u8, approval.child_id, child_id))
        {
            return error.InvalidRequest;
        }
        const relationship = approval.relationship orelse
            return error.InvalidRequest;
        const owned_child_id = try self.alloc.dupe(u8, approval.child_id);
        errdefer self.alloc.free(owned_child_id);
        const root_id = try self.alloc.dupe(u8, approval.root_id);
        errdefer self.alloc.free(root_id);
        const prospective_parent_id = try self.alloc.dupe(
            u8,
            relationship.prospective_parent_id,
        );
        errdefer self.alloc.free(prospective_parent_id);
        return .{
            .child_id = owned_child_id,
            .root_id = root_id,
            .action = relationship.action,
            .prospective_parent_id = prospective_parent_id,
            .operation_id = try self.alloc.dupe(u8, relationship.operation_id),
            .status = approval.status,
        };
    }

    const ApprovalRouting = struct {
        prospective_parent_id: ?[]u8,
    };

    fn loadApprovalRouting(
        self: *DurableRegistry,
        child_id: []const u8,
        request_id: []const u8,
    ) Error!ApprovalRouting {
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            self.alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var ledger = store.load(self.alloc) catch |err| return mapLoad(err);
        defer ledger.deinit(self.alloc);
        const approval = communication.findApproval(
            ledger.approvals,
            request_id,
        ) orelse return error.InvalidRequest;
        return .{
            .prospective_parent_id = if (approval.relationship) |relationship|
                try self.alloc.dupe(u8, relationship.prospective_parent_id)
            else
                null,
        };
    }

    fn invalidate(
        self: *DurableRegistry,
        request_id: []const u8,
        child_id: []const u8,
        status: communication.ApprovalStatus,
        timestamp_ms: i64,
    ) Error!void {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            self.alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        var store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var lock = store.acquireLock() catch |err| return mapLock(err);
        defer lock.release();
        var ledger = store.load(self.alloc) catch |err| return mapLoad(err);
        defer ledger.deinit(self.alloc);
        const approval = communication.findApproval(ledger.approvals, request_id) orelse
            return error.InvalidRequest;
        if (!std.mem.eql(u8, approval.child_id, child_id)) return error.InvalidRequest;
        if (approval.status == status) return;
        const relationship_terminalization = approval.kind == .relationship and
            approval.status == .allowed_once and status == .stale;
        if (approval.status != .pending and !relationship_terminalization) {
            return error.RequestResolved;
        }
        const revision = std.math.add(u64, ledger.generation, 1) catch
            return error.InvalidRequest;
        approval.status = status;
        approval.resolved_at_ms = timestamp_ms;
        approval.resolved_revision = revision;
        ledger.generation = revision;
        try save(store, self.alloc, ledger);
    }
};

const Locked = struct {
    id: []u8,
    capability: session_child_store.SessionChildCapability,
    lock: @import("../shared/io.zig").TimedAdvisoryLock,
};

const LockedChain = struct {
    alloc: Allocator,
    items: []Locked,

    fn acquire(
        alloc: Allocator,
        sessions: *session_store.Store,
        child_id: []const u8,
        options: session_child_store.Options,
    ) Error!LockedChain {
        const ids = try discoverChain(alloc, sessions, child_id, options);
        defer freeIds(alloc, ids);
        sortIds(ids);
        const items = try alloc.alloc(Locked, ids.len);
        errdefer alloc.free(items);
        var locked: usize = 0;
        errdefer {
            var index = locked;
            while (index > 0) {
                index -= 1;
                items[index].lock.release();
                items[index].capability.deinit();
                alloc.free(items[index].id);
            }
        }
        for (ids, 0..) |id, index| {
            const owned_id = try alloc.dupe(u8, id);
            errdefer alloc.free(owned_id);
            var capability = sessions.openSubagentControlCapabilityWritable(
                alloc,
                id,
                options,
            ) catch |err| return mapOpen(err);
            errdefer capability.deinit();
            var store = communication_store.Store{
                .capability = &capability,
                .expected_session_id = id,
            };
            const lock = store.acquireLock() catch |err| return mapLock(err);
            items[index] = .{
                .id = owned_id,
                .capability = capability,
                .lock = lock,
            };
            locked += 1;
        }
        return .{ .alloc = alloc, .items = items };
    }

    fn acquireRelationship(
        alloc: Allocator,
        sessions: *session_store.Store,
        child_id: []const u8,
        prospective_parent_id: []const u8,
        options: session_child_store.Options,
    ) Error!LockedChain {
        var ids = try discoverChainFrom(
            alloc,
            sessions,
            prospective_parent_id,
            options,
            false,
        );
        defer freeIds(alloc, ids);
        var contains_child = false;
        for (ids) |id| {
            if (std.mem.eql(u8, id, child_id)) contains_child = true;
        }
        if (!contains_child) {
            const owned_child_id = try alloc.dupe(u8, child_id);
            errdefer alloc.free(owned_child_id);
            ids = try alloc.realloc(ids, ids.len + 1);
            ids[ids.len - 1] = owned_child_id;
        }
        sortIds(ids);
        const items = try alloc.alloc(Locked, ids.len);
        errdefer alloc.free(items);
        var locked: usize = 0;
        errdefer {
            var index = locked;
            while (index > 0) {
                index -= 1;
                items[index].lock.release();
                items[index].capability.deinit();
                alloc.free(items[index].id);
            }
        }
        for (ids, 0..) |id, index| {
            const owned_id = try alloc.dupe(u8, id);
            errdefer alloc.free(owned_id);
            var capability = sessions.openSubagentControlCapabilityWritable(
                alloc,
                id,
                options,
            ) catch |err| return mapOpen(err);
            errdefer capability.deinit();
            const store = communication_store.Store{
                .capability = &capability,
                .expected_session_id = id,
            };
            const lock = store.acquireLock() catch |err| return mapLock(err);
            items[index] = .{
                .id = owned_id,
                .capability = capability,
                .lock = lock,
            };
            locked += 1;
        }
        return .{ .alloc = alloc, .items = items };
    }

    fn validate(
        self: *LockedChain,
        child_id: []const u8,
        expected_root_id: []const u8,
    ) Error!void {
        var current = try self.alloc.dupe(u8, child_id);
        defer self.alloc.free(current);
        var depth: usize = 0;
        while (depth < self.items.len) : (depth += 1) {
            const item = self.find(current) orelse return error.ChildNotAttached;
            var store = control_store.Store{
                .capability = &item.capability,
                .expected_child_id = current,
            };
            const maybe_record = store.loadOptional(self.alloc) catch |err|
                return mapControl(err);
            if (maybe_record) |loaded| {
                var record = loaded;
                defer record.deinit(self.alloc);
                if (record.parent_id) |parent_id| {
                    const next = try self.alloc.dupe(u8, parent_id);
                    self.alloc.free(current);
                    current = next;
                    continue;
                }
            }
            if (!std.mem.eql(u8, current, expected_root_id)) {
                return error.ChildNotAttached;
            }
            return;
        }
        return error.GraphTooDeep;
    }

    fn find(self: *LockedChain, id: []const u8) ?*Locked {
        for (self.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }

    fn deinit(self: *LockedChain, alloc: Allocator) void {
        var index = self.items.len;
        while (index > 0) {
            index -= 1;
            self.items[index].lock.release();
            self.items[index].capability.deinit();
            alloc.free(self.items[index].id);
        }
        alloc.free(self.items);
        self.* = undefined;
    }
};

fn discoverChain(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_id: []const u8,
    options: session_child_store.Options,
) Error![][]u8 {
    return discoverChainFrom(alloc, sessions, child_id, options, true);
}

fn discoverChainFrom(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_id: []const u8,
    options: session_child_store.Options,
    require_first_record: bool,
) Error![][]u8 {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer freeIdsList(alloc, &ids);
    var current = try alloc.dupe(u8, child_id);
    defer alloc.free(current);
    var depth: usize = 0;
    while (depth < max_ancestry_depth) : (depth += 1) {
        for (ids.items) |id| {
            if (std.mem.eql(u8, id, current)) return error.RelationshipCycle;
        }
        try ids.append(alloc, try alloc.dupe(u8, current));
        var capability = sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            current,
            options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = current,
        };
        const maybe_record = store.loadOptional(alloc) catch |err| return mapControl(err);
        if (maybe_record) |loaded| {
            var record = loaded;
            defer record.deinit(alloc);
            if (record.parent_id) |parent_id| {
                const next = try alloc.dupe(u8, parent_id);
                alloc.free(current);
                current = next;
                continue;
            }
        } else if (depth == 0 and require_first_record) {
            return error.ChildNotAttached;
        }
        return ids.toOwnedSlice(alloc);
    }
    return error.GraphTooDeep;
}

fn workIsActive(queue: []const domain.QueuedMessage, work_id: []const u8) bool {
    for (queue) |work| {
        if (!std.mem.eql(u8, work.id, work_id)) continue;
        return work.status == .running or work.status == .awaiting_approval;
    }
    return false;
}

fn approvalResponseMatches(
    approval: communication.Approval,
    response: communication.ApprovalResponse,
) bool {
    if (!std.mem.eql(u8, approval.id, response.request_id) or
        !std.mem.eql(u8, approval.child_id, response.child_id)) return false;
    return switch (response.decision) {
        .once => approval.status == .allowed_once,
        .always => approval.status == .allowed_always,
        .deny => approval.status == .denied,
        .policy_denied, .permission_required => false,
    };
}

fn loadOrInit(
    alloc: Allocator,
    store: communication_store.Store,
    session_id: []const u8,
) Error!communication.Ledger {
    const existing = store.loadOptional(alloc) catch |err| return mapLoad(err);
    if (existing) |ledger| return ledger;
    return communication.Ledger.init(alloc, session_id) catch
        return error.OutOfMemory;
}

fn save(
    store: communication_store.Store,
    alloc: Allocator,
    ledger: communication.Ledger,
) Error!void {
    store.save(alloc, ledger) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CommunicationCommitIndeterminate => error.CommitIndeterminate,
        error.CommunicationCapacityExceeded => error.CapacityExceeded,
        error.CommunicationIdentityMismatch,
        error.InvalidCommunicationRecord,
        => error.InvalidRequest,
        error.CommunicationRecordTooLarge,
        error.CommunicationPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.CommunicationStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapOpen(err: session_store.OpenSubagentControlError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId, error.SessionNotFound => error.ChildNotAttached,
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.SessionChildStoreFailed,
        error.SessionStoreUnavailable,
        => error.StoreUnavailable,
    };
}

fn mapControl(err: control_store.LoadError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlNotFound => error.ChildNotAttached,
        error.InvalidControlRecord, error.UnsupportedControlSchema => error.InvalidRequest,
        error.ControlRecordTooLarge,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapControlSave(err: control_store.SaveError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlCommitIndeterminate => error.CommitIndeterminate,
        error.ControlIdentityMismatch => error.InvalidRequest,
        error.ControlRecordTooLarge,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapLoad(err: communication_store.LoadError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CommunicationNotFound => error.InvalidRequest,
        error.InvalidCommunicationRecord,
        error.UnsupportedCommunicationSchema,
        => error.InvalidRequest,
        error.CommunicationRecordTooLarge,
        error.CommunicationPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.CommunicationStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapLock(err: communication_store.LockError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CommunicationLockBusy => error.LockBusy,
        error.CommunicationLockUnsupported => error.LockUnsupported,
        error.CommunicationPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.CommunicationStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapMutation(err: communication.MutationError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ApprovalConflict => error.RequestConflict,
        error.InvalidDelivery,
        error.GenerationExhausted,
        error.SequenceExhausted,
        error.TooManyConsumers,
        error.TooManyRetentionTargets,
        error.InvalidCursor,
        error.StaleCursor,
        error.InvalidNotification,
        error.UndeclaredMilestone,
        error.DuplicateMilestone,
        error.InvalidApproval,
        error.AuthorityExhausted,
        error.ReplayExpired,
        => error.InvalidRequest,
        error.CapacityExceeded => error.CapacityExceeded,
    };
}

fn mapPersistence(err: Error) approval_registry.PersistenceError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ChildNotAttached,
        error.RelationshipCycle,
        error.GraphTooDeep,
        error.InvalidRequest,
        error.RequestConflict,
        error.RequestResolved,
        error.LockBusy,
        error.LockUnsupported,
        error.StoreUnavailable,
        error.CommitIndeterminate,
        => error.CommitFailed,
        error.CapacityExceeded => error.CapacityExceeded,
    };
}

fn sortIds(ids: [][]u8) void {
    var index: usize = 1;
    while (index < ids.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and
            std.mem.order(u8, ids[cursor - 1], ids[cursor]) == .gt) : (cursor -= 1)
        {
            std.mem.swap([]u8, &ids[cursor - 1], &ids[cursor]);
        }
    }
}

fn freeIds(alloc: Allocator, ids: [][]u8) void {
    for (ids) |id| alloc.free(id);
    alloc.free(ids);
}

fn freeIdsList(alloc: Allocator, ids: *std.ArrayList([]u8)) void {
    for (ids.items) |id| alloc.free(id);
    ids.deinit(alloc);
}
