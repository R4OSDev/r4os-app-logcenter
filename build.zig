const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// `zig build` erzeugt das Modul allein aus diesem Verzeichnis, ohne den Rest
/// von R4OS. Die Datei zeigt nur auf module.R4MF - Name, Klasse, Quellen,
/// Ziel, Imports und Metadaten stehen dort und nirgends sonst.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
    const view_tests = b.createModule(.{ .root_source_file = b.path("src/source_view.zig"), .target = b.graph.host, .optimize = .Debug });
    view_tests.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    b.step("test", "Whole log source and record pages with revision retries")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = view_tests })).step);
}
