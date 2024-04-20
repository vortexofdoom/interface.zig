const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("interface.zig", .{
        .root_source_file = .{ .path = "src/interface.zig" },
    });

    const if_test = b.addTest(.{
        .root_source_file = .{ .path = "src/examples.zig" },
    });
    
    if_test.root_module.addImport("interface.zig", module);

    b.getInstallStep().dependOn(&b.addRunArtifact(if_test).step);
}
