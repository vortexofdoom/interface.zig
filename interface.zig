const std = @import("std");
const mem = std.mem;
const trait = std.meta.trait;

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

pub const SelfType = @OpaqueType();

fn makeSelfPtr(ptr: var) *SelfType {
    if (comptime !trait.isSingleItemPtr(@TypeOf(ptr))) {
        @compileError("SelfType pointer initialization expects pointer parameter.");
    }

    const T = std.meta.Child(@TypeOf(ptr));

    if (@sizeOf(T) > 0) {
        return @ptrCast(*SelfType, ptr);
    } else {
        return undefined;
    }
}

fn selfPtrAs(self: *SelfType, comptime T: type) *T {
    if (@sizeOf(T) > 0) {
        return @alignCast(@alignOf(T), @ptrCast(*align(1) T, self));
    } else {
        return undefined;
    }
}

fn constSelfPtrAs(self: *const SelfType, comptime T: type) *const T {
    if (@sizeOf(T) > 0) {
        return @alignCast(@alignOf(T), @ptrCast(*align(1) const T, self));
    } else {
        return undefined;
    }
}

pub const Storage = struct {
    pub const Comptime = struct {
        erased_ptr: *SelfType,
        ImplType: type,

        pub fn init(args: var) !Comptime {
            if (args.len != 1) {
                @compileError("Comptime storage expected a 1-tuple in initialization.");
            }

            var obj = args[0];

            return Comptime{
                .erased_ptr = makeSelfPtr(&obj),
                .ImplType = @TypeOf(args[0]),
            };
        }

        pub fn getSelfPtr(comptime self: *Comptime) *SelfType {
            return self.erased_ptr;
        }

        pub fn deinit(comptime self: Comptime) void {}
    };

    pub const NonOwning = struct {
        erased_ptr: *SelfType,

        pub fn init(args: var) !NonOwning {
            if (args.len != 1) {
                @compileError("NonOwning storage expected a 1-tuple in initialization.");
            }

            return NonOwning{
                .erased_ptr = makeSelfPtr(args[0]),
            };
        }

        pub fn getSelfPtr(self: NonOwning) *SelfType {
            return self.erased_ptr;
        }

        pub fn deinit(self: NonOwning) void {}
    };

    pub const Owning = struct {
        allocator: *mem.Allocator,
        mem: []u8,
        alignment: u29,

        pub fn init(args: var) !Owning {
            if (args.len != 2) {
                @compileError("Owning storage expected a 2-tuple in initialization.");
            }

            const AllocT = @TypeOf(args[0]);

            var obj = try args[1].create(AllocT);
            obj.* = args[0];

            return Owning{
                .allocator = args[1],
                .mem = std.mem.asBytes(obj)[0..],
                .alignment = @alignOf(AllocT),
            };
        }

        pub fn getSelfPtr(self: Owning) *SelfType {
            return makeSelfPtr(&self.mem[0]);
        }

        pub fn deinit(self: Owning) void {
            // We manually call into the allocator's shrink function.
            // 'destroy' and 'shrink' just use the pointer type to get alignment,
            // while  'alignedShrink' requires a comptime alignment.
            const result = self.allocator.shrinkFn(self.allocator, self.mem, self.alignment, 0, 1);
            assert(result.len == 0);
        }
    };

    pub fn Inline(comptime size: usize) type {
        return struct {
            const Self = @This();

            mem: [size]u8,

            pub fn init(args: var) !Self {
                if (args.len != 1) {
                    @compileError("Inline storage expected a 1-tuple in initialization.");
                }

                const ImplSize = @sizeOf(@TypeOf(args[0]));

                if (ImplSize > size) {
                    @compileError("Type does not fit in inline storage.");
                }

                var self: Self = undefined;

                if (ImplSize > 0) {
                    std.mem.copy(u8, self.mem[0..], @ptrCast([*]const u8, &args[0])[0..ImplSize]);
                }
                return self;
            }

            pub fn getSelfPtr(self: *Self) *SelfType {
                return makeSelfPtr(&self.mem[0]);
            }

            pub fn deinit(self: Self) void {}
        };
    }

    pub fn InlineOrOwning(comptime size: usize) type {
        return struct {
            const Self = @This();

            data: union(enum) {
                Inline: Inline(size),
                Owning: Owning,
            },

            pub fn init(args: var) !Self {
                if (args.len != 2) {
                    @compileError("InlineOrOwning storage expected a 2-tuple in initialization.");
                }

                const ImplSize = @sizeOf(@TypeOf(args[0]));

                if (ImplSize > size) {
                    return Self{
                        .data = .{
                            .Owning = try Owning.init(args),
                        },
                    };
                } else {
                    return Self{
                        .data = .{
                            .Inline = try Inline(size).init(.{args[0]}),
                        },
                    };
                }
            }

            pub fn getSelfPtr(self: *Self) *SelfType {
                return switch (self.data) {
                    .Inline => |*i| i.getSelfPtr(),
                    .Owning => |*o| o.getSelfPtr(),
                };
            }

            pub fn deinit(self: Self) void {
                switch (self.data) {
                    .Inline => |i| i.deinit(),
                    .Owning => |o| o.deinit(),
                }
            }
        };
    }
};

fn PtrChildOrSelf(comptime T: type) type {
    if (comptime trait.isSingleItemPtr(T)) {
        return std.meta.Child(T);
    }

    return T;
}

const GenCallType = enum {
    BothAsync,
    BothBlocking,
    AsyncCallsBlocking,
    BlockingCallsAsync,
};

fn makeCall(
    comptime name: []const u8,
    comptime CurrSelfType: type,
    comptime Return: type,
    comptime ImplT: type,
    comptime call_type: GenCallType,
    self_ptr: CurrSelfType,
    args: var,
) Return {
    const is_const = CurrSelfType == *const SelfType;
    const self = if (is_const) constSelfPtrAs(self_ptr, ImplT) else selfPtrAs(self_ptr, ImplT);
    const fptr = @field(self, name);

    return switch (call_type) {
        .BothBlocking => @call(.{ .modifier = .always_inline }, fptr, args),
        .AsyncCallsBlocking, .BothAsync => await @call(.{ .modifier = .async_kw }, fptr, args),
        .BlockingCallsAsync => @compileError("Trying to implement blocking virtual function " ++ name ++ " with async implementation."),
    };
}

fn getFunctionFromImpl(comptime name: []const u8, comptime FnT: type, comptime ImplT: type) ?FnT {
    const our_cc = @typeInfo(FnT).Fn.calling_convention;

    // Find the candidate in the implementation type.
    for (std.meta.declarations(ImplT)) |decl| {
        if (std.mem.eql(u8, name, decl.name)) {
            switch (decl.data) {
                .Fn => |fn_decl| {
                    const args = @typeInfo(fn_decl.fn_type).Fn.args;

                    if (args.len == 0) {
                        return null;
                    }

                    const arg0_type = args[0].arg_type.?;
                    if (arg0_type != ImplT and arg0_type != *ImplT and arg0_type != *const ImplT) {
                        return null;
                    }

                    const candidate_cc = @typeInfo(fn_decl.fn_type).Fn.calling_convention;
                    switch (candidate_cc) {
                        .Async, .Unspecified => {},
                        else => return null,
                    }

                    const Return = @typeInfo(FnT).Fn.return_type orelse noreturn;
                    const CurrSelfType = @typeInfo(FnT).Fn.args[0].arg_type.?;

                    const call_type: GenCallType = switch (our_cc) {
                        .Async => if (candidate_cc == .Async) .BothAsync else .AsyncCallsBlocking,
                        .Unspecified => if (candidate_cc == .Unspecified) .BothBlocking else .BlockingCallsAsync,
                        else => unreachable,
                    };

                    // TODO: Make this less hacky somehow?
                    // We need some new feature to do so unfortunately.
                    return switch (args.len) {
                        1 => struct {
                            fn impl(self_ptr: CurrSelfType) callconv(our_cc) Return {
                                return @call(.{ .modifier = .always_inline }, makeCall, .{ name, CurrSelfType, Return, ImplT, call_type, self_ptr, .{} });
                            }
                        }.impl,
                        2 => struct {
                            fn impl(self_ptr: CurrSelfType, arg: args[1].arg_type.?) callconv(our_cc) Return {
                                return @call(.{ .modifier = .always_inline }, makeCall, .{ name, CurrSelfType, Return, ImplT, call_type, self_ptr, .{arg} });
                            }
                        }.impl,
                        3 => struct {
                            fn impl(self_ptr: CurrSelfType, arg1: args[1].arg_type.?, arg2: args[2].arg_type.?) callconv(our_cc) Return {
                                return @call(.{ .modifier = .always_inline }, makeCall, .{ name, CurrSelfType, Return, ImplT, call_type, self_ptr, .{ arg1, arg2 } });
                            }
                        }.impl,
                        4 => struct {
                            fn impl(self_ptr: CurrSelfType, arg1: args[1].arg_type.?, arg2: args[2].arg_type.?, arg3: args[3].arg_type.?) callconv(our_cc) Return {
                                return @call(.{ .modifier = .always_inline }, makeCall, .{ name, CurrSelfType, Return, ImplT, call_type, self_ptr, .{ arg1, arg2, arg3 } });
                            }
                        }.impl,
                        5 => struct {
                            fn impl(self_ptr: CurrSelfType, arg1: args[1].arg_type.?, arg2: args[2].arg_type.?, arg3: args[3].arg_type.?, arg4: args[4].arg_type.?) callconv(our_cc) Return {
                                return @call(.{ .modifier = .always_inline }, makeCall, .{ name, CurrSelfType, Return, ImplT, call_type, self_ptr, .{ arg1, arg2, arg3, arg4 } });
                            }
                        }.impl,
                        6 => struct {
                            fn impl(self_ptr: CurrSelfType, arg1: args[1].arg_type.?, arg2: args[2].arg_type.?, arg3: args[3].arg_type.?, arg4: args[4].arg_type.?, arg5: args[5].arg_type.?) callconv(our_cc) Return {
                                return @call(.{ .modifier = .always_inline }, makeCall, .{ name, CurrSelfType, Return, ImplT, call_type, self_ptr, .{ arg1, arg2, arg3, arg4, arg5 } });
                            }
                        }.impl,
                        else => @compileError("Unsupported number of arguments, please provide a manually written vtable."),
                    };
                },
                else => return null,
            }
        }
    }

    return null;
}

fn makeVTable(comptime VTableT: type, comptime ImplT: type) VTableT {
    if (comptime !trait.isContainer(ImplT)) {
        @compileError("Type '" ++ @typeName(ImplT) ++ "' must be a container to implement interface.");
    }
    var vtable: VTableT = undefined;

    for (std.meta.fields(VTableT)) |field| {
        var fn_type = field.field_type;
        const is_optional = trait.is(.Optional)(fn_type);
        if (is_optional) {
            fn_type = std.meta.Child(fn_type);
        }

        const candidate = comptime getFunctionFromImpl(field.name, fn_type, ImplT);
        if (candidate == null and !is_optional) {
            @compileError("Type '" ++ @typeName(ImplT) ++ "' does not implement non optional function '" ++ field.name ++ "'.");
        } else if (!is_optional) {
            @field(vtable, field.name) = candidate.?;
        } else {
            @field(vtable, field.name) = candidate;
        }
    }

    return vtable;
}

fn checkVtableType(comptime VTableT: type) void {
    if (comptime !trait.is(.Struct)(VTableT)) {
        @compileError("VTable type " ++ @typeName(VTableT) ++ " must be a struct.");
    }

    for (std.meta.declarations(VTableT)) |decl| {
        switch (decl.data) {
            .Fn => @compileError("VTable type defines method '" ++ decl.name ++ "'."),
            .Type, .Var => {},
        }
    }

    for (std.meta.fields(VTableT)) |field| {
        var field_type = field.field_type;

        if (trait.is(.Optional)(field_type)) {
            field_type = std.meta.Child(field_type);
        }

        if (!trait.is(.Fn)(field_type)) {
            @compileError("VTable type defines non function field '" ++ field.name ++ "'.");
        }

        const type_info = @typeInfo(field_type);

        if (type_info.Fn.is_generic) {
            @compileError("Virtual function '" ++ field.name ++ "' cannot be generic.");
        }

        switch (type_info.Fn.calling_convention) {
            .Unspecified, .Async => {},
            else => @compileError("Virtual function's  '" ++ field.name ++ "' calling convention is not default or async."),
        }

        if (type_info.Fn.args.len == 0) {
            @compileError("Virtual function '" ++ field.name ++ "' must have at least one argument.");
        }

        const arg_type = type_info.Fn.args[0].arg_type.?;
        if (arg_type != *SelfType and arg_type != *const SelfType) {
            @compileError("Virtual function's '" ++ field.name ++ "' first argument must be *SelfType or *const SelfType");
        }
    }
}

fn vtableHasMethod(comptime VTableT: type, comptime name: []const u8, is_optional: *bool, is_async: *bool) bool {
    for (std.meta.fields(VTableT)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            is_optional.* = trait.is(.Optional)(field.field_type);
            is_async.* = @typeInfo(if (is_optional.*) std.meta.Child(field.field_type) else field.field_type).Fn.calling_convention == .Async;
            return true;
        }
    }

    return false;
}

fn VTableReturnType(comptime VTableT: type, comptime name: []const u8) type {
    for (std.meta.fields(VTableT)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            const is_optional = trait.is(.Optional)(field.field_type);

            var fn_ret_type = (if (is_optional)
                @typeInfo(std.meta.Child(field.field_type)).Fn.return_type
            else
                @typeInfo(field.field_type).Fn.return_type) orelse noreturn;

            if (is_optional) {
                return ?fn_ret_type;
            }

            return fn_ret_type;
        }
    }

    @compileError("VTable type '" ++ @typeName(VTableT) ++ "' has no virtual function '" ++ name ++ "'.");
}

pub fn Interface(comptime VTableT: type, comptime StorageT: type) type {
    comptime checkVtableType(VTableT);

    const stack_size: usize = if (@hasDecl(VTableT, "async_call_stack_size"))
        VTableT.async_call_stack_size
    else
        1 * 1024 * 1024;

    return struct {
        vtable_ptr: *const VTableT,
        storage: StorageT,

        const Self = @This();

        pub fn init(args: var) !Self {
            const ImplType = PtrChildOrSelf(@TypeOf(args.@"0"));

            return Self{
                .vtable_ptr = &comptime makeVTable(VTableT, ImplType),
                .storage = try StorageT.init(args),
            };
        }

        pub fn initWithVTable(vtable_ptr: *const VTableT, args: var) !Self {
            return .{
                .vtable_ptr = vtable_ptr,
                .storage = try StorageT.init(args),
            };
        }

        pub fn call(self: var, comptime name: []const u8, args: var) VTableReturnType(VTableT, name) {
            comptime var is_optional = true;
            comptime var is_async = true;
            comptime assert(vtableHasMethod(VTableT, name, &is_optional, &is_async));

            const fn_ptr = if (is_optional) blk: {
                const val = @field(self.vtable_ptr, name);
                if (val) |v| break :blk v;
                return null;
            } else @field(self.vtable_ptr, name);

            const self_ptr = self.storage.getSelfPtr();
            const new_args = .{self_ptr};

            if (!is_async) {
                return @call(.{}, fn_ptr, new_args ++ args);
            } else {
                var stack_frame: [stack_size]u8 align(std.Target.stack_align) = undefined;
                // For now, only work for for zero arg functions
                if (args.len != 0 and args.len != 1) {
                    @compileError("TODO: @asyncCall should take an argument tuple pack instead of varargs (see #4621)");
                }

                if (args.len == 0)
                    return await @asyncCall(&stack_frame, {}, fn_ptr, self_ptr);

                return await @asyncCall(&stack_frame, {}, fn_ptr, self_ptr, args[0]);
            }
        }

        pub fn deinit(self: Self) void {
            self.storage.deinit();
        }
    };
}
