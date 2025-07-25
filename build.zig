const std = @import("std");

const log = std.log.scoped(.necromach_gpu_dawn);

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    try prepPathStrings(b.allocator);

    const options = Options{
        .install_libs = true,
        .from_source = true,
    };
    // Just to demonstrate/test linking. This is not a functional example, see the mach/gpu examples
    // or Dawn C++ examples for functional example code.
    const example = b.addExecutable(.{
        .name = "empty",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    try link(b, example, example.root_module, options);

    const example_step = b.step("dawn", "Build dawn from source");
    example_step.dependOn(&b.addRunArtifact(example).step);

    _ = b.step("check", "Do nothing, but at least zls won't starve your cpu trying to run cmake");
}

pub const DownloadBinaryStep = struct {
    target: *std.Build.Step.Compile,
    options: Options,
    step: std.Build.Step,
    b: *std.Build,

    pub fn init(b: *std.Build, target: *std.Build.Step.Compile, options: Options) *DownloadBinaryStep {
        const download_step = b.allocator.create(DownloadBinaryStep) catch unreachable;
        download_step.* = .{
            .target = target,
            .options = options,
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "download",
                .owner = b,
                .makeFn = &make,
            }),
            .b = b,
        };
        return download_step;
    }

    fn make(step: *std.Build.Step, make_options: std.Build.Step.MakeOptions) anyerror!void {
        _ = make_options;
        const download_step: *DownloadBinaryStep = @fieldParentPtr("step", step);
        try downloadFromBinary(download_step.b, download_step.target, download_step.options);
    }
};

pub const Options = struct {
    /// Defaults to true on Windows
    d3d12: ?bool = null,

    /// Defaults to true on Darwin
    metal: ?bool = null,

    /// Defaults to true on Linux, Fuchsia
    // TODO(build-system): enable on Windows if we can cross compile Vulkan
    vulkan: ?bool = null,

    /// Defaults to true on Linux
    desktop_gl: ?bool = null,

    /// Defaults to true on Android, Linux, Windows, Emscripten
    // TODO(build-system): not respected at all currently
    opengl_es: ?bool = null,

    /// Whether or not minimal debug symbols should be emitted. This is -g1 in most cases, enough to
    /// produce stack traces but omitting debug symbols for locals. For spirv-tools and tint in
    /// specific, -g0 will be used (no debug symbols at all) to save an additional ~39M.
    debug: bool = false,

    /// Whether or not to produce separate static libraries for each component of Dawn (reduces
    /// iteration times when building from source / testing changes to Dawn source code.)
    separate_libs: bool = false,

    /// Whether or not to produce shared libraries instead of static ones
    shared_libs: bool = false,

    /// Whether to build Dawn from source or not.
    from_source: bool = false,

    /// Produce static libraries at zig-out/lib
    install_libs: bool = false,

    /// The binary release version to use from https://github.com/hexops/mach-gpu-dawn/releases
    binary_version: []const u8 = "release-9c05275",

    /// Detects the default options to use for the given target.
    pub fn detectDefaults(self: Options, target: std.Target) Options {
        const tag = target.os.tag;

        var options = self;
        if (options.d3d12 == null) options.d3d12 = tag == .windows;
        if (options.metal == null) options.metal = tag.isDarwin();
        if (options.vulkan == null) options.vulkan = tag == .fuchsia or isLinuxDesktopLike(tag);

        // TODO(build-system): technically Dawn itself defaults desktop_gl to true on Windows.
        if (options.desktop_gl == null) options.desktop_gl = isLinuxDesktopLike(tag);

        // TODO(build-system): OpenGL ES
        options.opengl_es = false;
        // if (options.opengl_es == null) options.opengl_es = tag == .windows or tag == .emscripten or target.isAndroid() or linux_desktop_like;

        return options;
    }
};

pub fn link(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) !void {
    const target = step.rootModuleTarget();
    const opt = options.detectDefaults(target);

    //
    //
    try linkFromSource(b, step, mod, opt);
    //
    //

    // if (target.os.tag == .windows) @import("direct3d_headers").addLibraryPath(step);
    // if (target.os.tag == .macos) @import("xcode_frameworks").addPaths(mod);

    // if (options.from_source or isEnvVarTruthy(b.allocator, "DAWN_FROM_SOURCE")) {
    //     linkFromSource(b, step, mod, opt) catch unreachable;
    // } else {
    //     // Add a build step to download Dawn binaries. This ensures it only downloads if needed,
    //     // and that e.g. if you are running a different `zig build <step>` it doesn't always just
    //     // download the binaries.
    //     var download_step = DownloadBinaryStep.init(b, step, options);
    //     step.step.dependOn(&download_step.step);

    //     // Declare how to link against the binaries.
    //     linkFromBinary(b, step, mod, opt) catch unreachable;
    // }
}

fn isTargetSupported(target: std.Target) bool {
    return switch (target.os.tag) {
        .windows => target.abi.isGnu(),
        .linux => (target.cpu.arch.isX86() or target.cpu.arch.isAARCH64()) and (target.abi.isGnu() or target.abi.isMusl()),
        .macos => blk: {
            if (!target.cpu.arch.isX86() and !target.cpu.arch.isAARCH64()) break :blk false;

            // The minimum macOS version with which our binaries can be used.
            const min_available = std.SemanticVersion{ .major = 11, .minor = 0, .patch = 0 };

            // If the target version is >= the available version, then it's OK.
            const order = target.os.version_range.semver.min.order(min_available);
            break :blk (order == .gt or order == .eq);
        },
        else => false,
    };
}

fn linkFromSource(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) !void {
    _ = mod;
    // Source scanning requires that these files actually exist on disk, so we must download them
    // here right now if we are building from source.
    try ensureGitRepoCloned(b.allocator, "https://github.com/a-day-old-bagel/necromach-dawn", "b5ed9ad6bb457ca1fbaa89d53b4bf27ba6d75ed0", sdkPath("/libs/dawn"));

    _ = options;

    {
        const target_triple = try step.rootModuleTarget().zigTriple(b.allocator);
        const cmake_d_target = try std.fmt.allocPrint(b.allocator, "-DTARGET={s}", .{target_triple});

        if (!isTargetSupported(step.rootModuleTarget())) {
            std.log.err("Target {s} is not currently supported.", .{target_triple});
            return error.TargetNotSupported;
        } else {
            std.log.info("Building zdawn for target {s}.", .{target_triple});
        }

        try exec(b.allocator, &.{
            "cmake",
            "-G",
            "Ninja",
            "-B",
            "build",
            "-DCMAKE_TOOLCHAIN_FILE=zig-toolchain.cmake",
            cmake_d_target,
            "-DCMAKE_BUILD_TYPE=Release",
        }, sdkPath("."));

        try exec(b.allocator, &.{
            "cmake",
            "--build",
            "./build",
            "--config",
            "Release",
        }, sdkPath("."));
    }

    {
        const cwd = std.fs.cwd();
        // var obj_dir = try cwd.makeOpenPath("build/objects", .{ .iterate = true });
        // defer obj_dir.close();

        var archive_paths = std.ArrayList(std.Build.LazyPath).init(b.allocator);
        // try archive_paths.append(b.dependency("mach_dxc", .{}).path("machdxcompiler.lib"));
        // try archive_paths.append(b.dependency("mach_dxc", .{}).path("dawn_weak.lib"));
        // try archive_paths.append(b.path("build/libmingw_helpers.a"));
        // try archive_paths.append(b.path("build/dawn.lib"));
        // try archive_paths.append(b.path("build/libs/dawn/src/dawn/native/libwebgpu_dawn.a"));
        // try archive_paths.append(b.path("build/libs/dawn/third_party/spirv-tools/source/libSPIRV-Tools.a"));
        // try archive_paths.append(b.path("build/libs/dawn/third_party/spirv-tools/source/opt/libSPIRV-Tools-opt.a"));

        // try archive_paths.append(b.path("build/libs/dawn/src/tint/libtint_lang_core_ir.a"));

        // const tint_dir_path = "build/libs/dawn/src/tint";
        // const tint_dir = try cwd.makeOpenPath(tint_dir_path, .{ .iterate = true });
        // var tint_it = tint_dir.iterate();
        // while (try tint_it.next()) |tint_file| {
        //     if (std.mem.endsWith(u8, tint_file.name, ".a")) {
        //         const archive_path = try b.path(tint_dir_path).join(b.allocator, tint_file.name);
        //         try archive_paths.append(archive_path);
        //     }
        // }

        try archive_paths.append(b.path("build/libs/dawn/src/dawn/native/libwebgpu_dawn.a"));

        for (archive_paths.items) |archive| {
            const obj_out_dir_path = (try b.path("build/objects").join(b.allocator, archive.getDisplayName())).getPath(b);
            var obj_out_dir = try cwd.makeOpenPath(obj_out_dir_path, .{});
            defer obj_out_dir.close();
            try exec(b.allocator, &.{ "zig", "ar", "x", archive.getPath(b) }, obj_out_dir_path);
        }
    }

    const zdawn_module = b.addModule("root", .{
        .root_source_file = b.path("src/zdawn.zig"),
        .target = step.root_module.resolved_target,
        .optimize = step.root_module.optimize,
    });
    zdawn_module.addIncludePath(b.path("build/libs/dawn/gen/include"));
    zdawn_module.strip = true;

    const zdawn_lib = b.addSharedLibrary(.{
        // const zdawn_lib = b.addStaticLibrary(.{
        .name = "zdawn",
        // .target = step.root_module.resolved_target,
        // .optimize = step.root_module.optimize,
        .root_module = zdawn_module,
    });
    b.installArtifact(zdawn_lib);
    zdawn_lib.link_gc_sections = true;
    // zdawn_lib.want_lto = false;
    // zdawn_lib.verbose_link = true;

    zdawn_lib.link_data_sections = true;
    zdawn_lib.link_function_sections = true;

    // {
    //     zdawn_lib.addLibraryPath(b.dependency("mach_dxc", .{}).path("."));
    //     // zdawn_lib.linkSystemLibrary("machdxcompiler_pruned2");
    //     // zdawn_lib.linkSystemLibrary2("machdxcompiler", .{ .weak = true });

    //     zdawn_lib.addLibraryPath(b.path("build"));
    //     zdawn_lib.linkSystemLibrary("mingw_helpers");

    //     // zdawn_lib.linkSystemLibrary2("dawn_weak", .{ .weak = true });
    //     zdawn_lib.linkSystemLibrary("dawn_weak");
    //     // zdawn_lib.linkSystemLibrary2("dawn", .{});

    //     zdawn_lib.addLibraryPath(b.path("build/libs/dawn/src/dawn/native"));
    //     zdawn_lib.linkSystemLibrary("webgpu_dawn");

    //     // zdawn_lib.addLibraryPath(b.path("build/libs/dawn/src/tint"));
    //     // zdawn_lib.linkSystemLibrary("tint_lang_core_type");

    //     // zdawn_lib.addLibraryPath(b.path("build/libs/dawn/third_party/spirv-tools/source"));
    //     // zdawn_lib.addLibraryPath(b.path("build/libs/dawn/third_party/spirv-tools/source/opt"));
    //     // zdawn_lib.linkSystemLibrary("SPIRV-Tools");
    //     // zdawn_lib.linkSystemLibrary("SPIRV-Tools-opt");

    // }

    // {
    //     zdawn_lib.addObjectFile(b.path("build/libs/dawn/src/dawn/native/libwebgpu_dawn.a"));
    //     zdawn_lib.addObjectFile(b.dependency("mach_dxc", .{}).path("dawn_weak.lib"));
    // }

    // {
    //     zdawn_lib.addObjectFile(b.path("build/objects/dependency/dxcapi.obj"));
    // }

    {
        const cwd = std.fs.cwd();
        var obj_dir = try cwd.makeOpenPath("build/objects", .{ .iterate = true });
        defer obj_dir.close();
        var obj_walker = try obj_dir.walk(b.allocator);
        while (try obj_walker.next()) |entry| {
            if (entry.kind == .file) {
                // if (std.mem.eql(u8, entry.basename, "AnalysisBasedWarnings.obj")) continue;
                // if (std.mem.eql(u8, entry.basename, "DxilMetadataHelper.obj")) continue;
                // if (std.mem.eql(u8, entry.basename, "DxilRootSignatureValidator.obj")) continue;
                zdawn_lib.addObjectFile(try b.path("build/objects").join(b.allocator, entry.path));
            }
        }
    }

    {
        zdawn_lib.linkLibC();
        zdawn_lib.linkLibCpp();
        // zdawn_lib.linkSystemLibrary("oleaut32");
        // zdawn_lib.linkSystemLibrary("ole32");
        // zdawn_lib.linkSystemLibrary("dbghelp");
        // zdawn_lib.linkSystemLibrary("dxguid");

        // zdawn_lib.linkSystemLibrary("clang");
    }

    step.linkLibrary(zdawn_lib);
}

fn ensureGitRepoCloned(allocator: std.mem.Allocator, clone_url: []const u8, revision: []const u8, dir: []const u8) !void {
    if (isEnvVarTruthy(allocator, "NO_ENSURE_SUBMODULES") or isEnvVarTruthy(allocator, "NO_ENSURE_GIT")) {
        return;
    }

    ensureGit(allocator);

    if (std.fs.openDirAbsolute(dir, .{})) |_| {
        const current_revision = try getCurrentGitRevision(allocator, dir);
        if (!std.mem.eql(u8, current_revision, revision)) {
            // Reset to the desired revision
            exec(allocator, &[_][]const u8{ "git", "fetch" }, dir) catch |err| std.debug.print("warning: failed to 'git fetch' in {s}: {s}\n", .{ dir, @errorName(err) });
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            // try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
        }
        return;
    } else |err| return switch (err) {
        error.FileNotFound => {
            std.log.info("cloning required dependency..\ngit clone {s} {s}..\n", .{ clone_url, dir });

            try exec(allocator, &[_][]const u8{ "git", "clone", "-c", "core.longpaths=true", clone_url, dir }, sdkPath("/"));
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            // try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
            return;
        },
        else => err,
    };
}

fn exec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    _ = try child.spawnAndWait();
}

fn getCurrentGitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = cwd });
    allocator.free(result.stderr);
    if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
    return result.stdout;
}

fn ensureGit(allocator: std.mem.Allocator) void {
    const argv = &[_][]const u8{ "git", "--version" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = ".",
    }) catch { // e.g. FileNotFound
        std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
        std.process.exit(1);
    };
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term.Exited != 0) {
        std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
        std.process.exit(1);
    }
}

fn isEnvVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
        defer allocator.free(truthy);
        if (std.mem.eql(u8, truthy, "true")) return true;
        return false;
    } else |_| {
        return false;
    }
}

fn getGitHubBaseURLOwned(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "MACH_GITHUB_BASE_URL")) |base_url| {
        std.log.info("mach: respecting MACH_GITHUB_BASE_URL: {s}\n", .{base_url});
        return base_url;
    } else |_| {
        return allocator.dupe(u8, "https://github.com");
    }
}

var download_mutex = std.Thread.Mutex{};

pub fn downloadFromBinary(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !void {
    // Zig will run build steps in parallel if possible, so if there were two invocations of
    // link() then this function would be called in parallel. We're manipulating the FS here
    // and so need to prevent that.
    download_mutex.lock();
    defer download_mutex.unlock();

    const target = step.rootModuleTarget();
    const binaries_available = switch (target.os.tag) {
        .windows => target.abi.isGnu(),
        .linux => (target.cpu.arch.isX86() or target.cpu.arch.isAARCH64()) and (target.abi.isGnu() or target.abi.isMusl()),
        .macos => blk: {
            if (!target.cpu.arch.isX86() and !target.cpu.arch.isAARCH64()) break :blk false;

            // The minimum macOS version with which our binaries can be used.
            const min_available = std.SemanticVersion{ .major = 11, .minor = 0, .patch = 0 };

            // If the target version is >= the available version, then it's OK.
            const order = target.os.version_range.semver.min.order(min_available);
            break :blk (order == .gt or order == .eq);
        },
        else => false,
    };
    if (!binaries_available) {
        const zig_triple = try target.zigTriple(b.allocator);
        std.log.err("dawn binaries for {s} not available.", .{zig_triple});
        std.log.err("-> build from source (takes 5-15 minutes):", .{});
        std.log.err("    set `DAWN_FROM_SOURCE` environment variable or `Options.from_source` to `true`\n", .{});
        if (target.os.tag == .macos) {
            std.log.err("", .{});
            if (target.cpu.arch.isX86()) std.log.err("-> Did you mean to use -Dtarget=x86_64-macos.12.0...13.1-none ?", .{});
            if (target.cpu.arch.isAARCH64()) std.log.err("-> Did you mean to use -Dtarget=aarch64-macos.12.0...13.1-none ?", .{});
        }
        std.process.exit(1);
    }

    // Remove OS version range / glibc version from triple (we do not include that in our download
    // URLs.)
    var binary_target = std.Target.Query.fromTarget(target);
    binary_target.os_version_min = .{ .none = undefined };
    binary_target.os_version_max = .{ .none = undefined };
    binary_target.glibc_version = null;
    const zig_triple = try binary_target.zigTriple(b.allocator);
    try ensureBinaryDownloaded(
        b.allocator,
        b.cache_root.path,
        zig_triple,
        options.debug,
        target.os.tag == .windows,
        options.binary_version,
    );
}

// pub fn linkFromBinary(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) !void {
//     const target = step.rootModuleTarget();

//     // Remove OS version range / glibc version from triple (we do not include that in our download
//     // URLs.)
//     var binary_target = std.Target.Query.fromTarget(target);
//     binary_target.os_version_min = .{ .none = undefined };
//     binary_target.os_version_max = .{ .none = undefined };
//     binary_target.glibc_version = null;
//     const zig_triple = try binary_target.zigTriple(b.allocator);

//     const base_cache_dir_rel = try std.fs.path.join(b.allocator, &.{
//         b.cache_root.path orelse "zig-cache",
//         "mach",
//         "gpu-dawn",
//     });
//     try std.fs.cwd().makePath(base_cache_dir_rel);
//     const base_cache_dir = try std.fs.cwd().realpathAlloc(b.allocator, base_cache_dir_rel);
//     const commit_cache_dir = try std.fs.path.join(b.allocator, &.{ base_cache_dir, options.binary_version });
//     const release_tag = if (options.debug) "debug" else "release-fast";
//     const target_cache_dir = try std.fs.path.join(b.allocator, &.{ commit_cache_dir, zig_triple, release_tag });
//     const include_dir = try std.fs.path.join(b.allocator, &.{ commit_cache_dir, "include" });

//     step.addLibraryPath(.{ .cwd_relative = target_cache_dir });
//     step.linkSystemLibrary("dawn");
//     step.linkLibCpp();

//     step.addIncludePath(.{ .cwd_relative = include_dir });
//     step.addIncludePath(.{ .cwd_relative = sdkPath("/src/dawn") });

//     linkLibDawnCommonDependencies(b, step, mod, options);
//     linkLibDawnPlatformDependencies(b, step, mod, options);
//     linkLibDawnNativeDependencies(b, step, mod, options);
//     linkLibTintDependencies(b, step, mod, options);
//     linkLibSPIRVToolsDependencies(b, step, mod, options);
//     linkLibAbseilCppDependencies(b, step, mod, options);
//     linkLibDawnWireDependencies(b, step, mod, options);
//     linkLibDxcompilerDependencies(b, step, mod, options);

//     // Transitive dependencies, explicit linkage of these works around
//     // ziglang/zig#17130
//     if (target.os.tag == .macos) {
//         step.linkFramework("CoreImage");
//         step.linkFramework("CoreVideo");
//     }
// }

pub fn addPathsToModule(b: *std.Build, module: *std.Build.Module, options: Options) void {
    const target = (module.resolved_target orelse b.host).result;
    const opt = options.detectDefaults(target);

    if (options.from_source or isEnvVarTruthy(b.allocator, "DAWN_FROM_SOURCE")) {
        addPathsToModuleFromSource(b, module, opt) catch unreachable;
    } else {
        addPathsToModuleFromBinary(b, module, opt) catch unreachable;
    }
}

pub fn addPathsToModuleFromSource(b: *std.Build, module: *std.Build.Module, options: Options) !void {
    _ = b;
    _ = options;

    module.addIncludePath(.{ .cwd_relative = sdkPath("/libs/dawn/out/Release/gen/include") });
    module.addIncludePath(.{ .cwd_relative = sdkPath("/libs/dawn/include") });
    module.addIncludePath(.{ .cwd_relative = sdkPath("/src/dawn") });
}

pub fn addPathsToModuleFromBinary(b: *std.Build, module: *std.Build.Module, options: Options) !void {
    const target = (module.resolved_target orelse b.host).result;

    // Remove OS version range / glibc version from triple (we do not include that in our download
    // URLs.)
    var binary_target = std.Target.Query.fromTarget(target);
    binary_target.os_version_min = .{ .none = undefined };
    binary_target.os_version_max = .{ .none = undefined };
    binary_target.glibc_version = null;
    const zig_triple = try binary_target.zigTriple(b.allocator);

    const base_cache_dir_rel = try std.fs.path.join(b.allocator, &.{
        b.cache_root.path orelse "zig-cache",
        "mach",
        "gpu-dawn",
    });
    try std.fs.cwd().makePath(base_cache_dir_rel);
    const base_cache_dir = try std.fs.cwd().realpathAlloc(b.allocator, base_cache_dir_rel);
    const commit_cache_dir = try std.fs.path.join(b.allocator, &.{ base_cache_dir, options.binary_version });
    const release_tag = if (options.debug) "debug" else "release-fast";
    const target_cache_dir = try std.fs.path.join(b.allocator, &.{ commit_cache_dir, zig_triple, release_tag });
    _ = target_cache_dir;
    const include_dir = try std.fs.path.join(b.allocator, &.{ commit_cache_dir, "include" });

    module.addIncludePath(.{ .cwd_relative = include_dir });
    module.addIncludePath(.{ .cwd_relative = sdkPath("/src/dawn") });
}

pub fn ensureBinaryDownloaded(
    allocator: std.mem.Allocator,
    cache_root: ?[]const u8,
    zig_triple: []const u8,
    is_debug: bool,
    is_windows: bool,
    version: []const u8,
) !void {
    // If zig-cache/mach/gpu-dawn/<git revision> does not exist:
    //   If on a commit in the main branch => rm -r zig-cache/mach/gpu-dawn/
    //   else => noop
    // If zig-cache/mach/gpu-dawn/<git revision>/<target> exists:
    //   noop
    // else:
    //   Download archive to zig-cache/mach/gpu-dawn/download/macos-aarch64
    //   Extract to zig-cache/mach/gpu-dawn/<git revision>/macos-aarch64/libgpu.a
    //   Remove zig-cache/mach/gpu-dawn/download

    const base_cache_dir_rel = try std.fs.path.join(allocator, &.{ cache_root orelse "zig-cache", "mach", "gpu-dawn" });
    try std.fs.cwd().makePath(base_cache_dir_rel);
    const base_cache_dir = try std.fs.cwd().realpathAlloc(allocator, base_cache_dir_rel);
    const commit_cache_dir = try std.fs.path.join(allocator, &.{ base_cache_dir, version });
    defer {
        allocator.free(base_cache_dir_rel);
        allocator.free(base_cache_dir);
        allocator.free(commit_cache_dir);
    }

    if (!dirExists(commit_cache_dir)) {
        // Commit cache dir does not exist. If the commit we're on is in the main branch, we're
        // probably moving to a newer commit and so we should cleanup older cached binaries.
        const current_git_commit = try getCurrentGitCommit(allocator);
        if (gitBranchContainsCommit(allocator, "main", current_git_commit) catch false) {
            std.fs.deleteTreeAbsolute(base_cache_dir) catch {};
        }
    }

    const release_tag = if (is_debug) "debug" else "release-fast";
    const target_cache_dir = try std.fs.path.join(allocator, &.{ commit_cache_dir, zig_triple, release_tag });
    defer allocator.free(target_cache_dir);
    if (dirExists(target_cache_dir)) {
        return; // nothing to do, already have the binary
    }
    downloadBinary(allocator, commit_cache_dir, release_tag, target_cache_dir, zig_triple, is_windows, version) catch |err| {
        // A download failed, or extraction failed, so wipe out the directory to ensure we correctly
        // try again next time.
        std.fs.deleteTreeAbsolute(base_cache_dir) catch {};
        std.log.err("mach/gpu-dawn: prebuilt binary download failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn downloadBinary(
    allocator: std.mem.Allocator,
    commit_cache_dir: []const u8,
    release_tag: []const u8,
    target_cache_dir: []const u8,
    zig_triple: []const u8,
    is_windows: bool,
    version: []const u8,
) !void {
    const download_dir = try std.fs.path.join(allocator, &.{ target_cache_dir, "download" });
    defer allocator.free(download_dir);
    std.fs.cwd().makePath(download_dir) catch @panic(download_dir);
    std.debug.print("download_dir: {s}\n", .{download_dir});

    // Replace "..." with "---" because GitHub releases has very weird restrictions on file names.
    // https://twitter.com/slimsag/status/1498025997987315713
    const github_triple = try std.mem.replaceOwned(u8, allocator, zig_triple, "...", "---");
    defer allocator.free(github_triple);

    // Compose the download URL, e.g.:
    // https://github.com/hexops/mach-gpu-dawn/releases/download/release-6b59025/libdawn_x86_64-macos-none_debug.a.gz
    const github_base_url = try getGitHubBaseURLOwned(allocator);
    defer allocator.free(github_base_url);
    const lib_prefix = if (is_windows) "dawn_" else "libdawn_";
    const lib_ext = if (is_windows) ".lib" else ".a";
    const lib_file_name = if (is_windows) "dawn.lib" else "libdawn.a";
    const download_url = try std.mem.concat(allocator, u8, &.{
        github_base_url,
        "/hexops/mach-gpu-dawn/releases/download/",
        version,
        "/",
        lib_prefix,
        github_triple,
        "_",
        release_tag,
        lib_ext,
        ".gz",
    });
    defer allocator.free(download_url);

    // Download and decompress libdawn
    const gz_target_file = try std.fs.path.join(allocator, &.{ download_dir, "compressed.gz" });
    defer allocator.free(gz_target_file);
    downloadFile(allocator, gz_target_file, download_url) catch @panic(gz_target_file);
    const target_file = try std.fs.path.join(allocator, &.{ target_cache_dir, lib_file_name });
    defer allocator.free(target_file);
    log.info("extracting {s}\n", .{gz_target_file});
    try gzipDecompress(allocator, gz_target_file, target_file);
    log.info("finished\n", .{});

    // If we don't yet have the headers (these are shared across architectures), download them.
    const include_dir = try std.fs.path.join(allocator, &.{ commit_cache_dir, "include" });
    defer allocator.free(include_dir);
    if (!dirExists(include_dir)) {
        // Compose the headers download URL, e.g.:
        // https://github.com/hexops/mach-gpu-dawn/releases/download/release-6b59025/headers.json.gz
        const headers_download_url = try std.mem.concat(allocator, u8, &.{
            github_base_url,
            "/hexops/mach-gpu-dawn/releases/download/",
            version,
            "/headers.json.gz",
        });
        defer allocator.free(headers_download_url);

        // Download and decompress headers.json.gz
        const headers_gz_target_file = try std.fs.path.join(allocator, &.{ download_dir, "headers.json.gz" });
        defer allocator.free(headers_gz_target_file);
        downloadFile(allocator, headers_gz_target_file, headers_download_url) catch @panic(headers_gz_target_file);
        const headers_target_file = try std.fs.path.join(allocator, &.{ target_cache_dir, "headers.json" });
        defer allocator.free(headers_target_file);
        gzipDecompress(allocator, headers_gz_target_file, headers_target_file) catch @panic(headers_target_file);

        // Extract headers JSON archive.
        extractHeaders(allocator, headers_target_file, commit_cache_dir) catch @panic(commit_cache_dir);
    }

    try std.fs.deleteTreeAbsolute(download_dir);
}

fn extractHeaders(allocator: std.mem.Allocator, json_file: []const u8, out_dir: []const u8) !void {
    const contents = try std.fs.cwd().readFileAlloc(allocator, json_file, std.math.maxInt(usize));
    defer allocator.free(contents);

    var tree = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer tree.deinit();

    var iter = tree.value.object.iterator();
    while (iter.next()) |f| {
        const out_path = try std.fs.path.join(allocator, &.{ out_dir, f.key_ptr.* });
        defer allocator.free(out_path);
        try std.fs.cwd().makePath(std.fs.path.dirname(out_path).?);

        var new_file = try std.fs.createFileAbsolute(out_path, .{});
        defer new_file.close();
        try new_file.writeAll(f.value_ptr.*.string);
    }
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn gzipDecompress(allocator: std.mem.Allocator, src_absolute_path: []const u8, dst_absolute_path: []const u8) !void {
    var file = try std.fs.openFileAbsolute(src_absolute_path, .{ .mode = .read_only });
    defer file.close();

    var buf_stream = std.io.bufferedReader(file.reader());
    var decompressor = std.compress.gzip.decompressor(buf_stream.reader());

    // Read and decompress the whole file
    const buf = try decompressor.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(buf);

    var new_file = try std.fs.createFileAbsolute(dst_absolute_path, .{});
    defer new_file.close();

    try new_file.writeAll(buf);
}

fn gitBranchContainsCommit(allocator: std.mem.Allocator, branch: []const u8, commit: []const u8) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "branch", branch, "--contains", commit },
        .cwd = sdkPath("/"),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term.Exited == 0;
}

fn getCurrentGitCommit(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = sdkPath("/"),
    });
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
    return result.stdout;
}

fn gitClone(allocator: std.mem.Allocator, repository: []const u8, dir: []const u8) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "clone", repository, dir },
        .cwd = sdkPath("/"),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term.Exited == 0;
}

fn downloadFile(allocator: std.mem.Allocator, target_file_path: []const u8, url: []const u8) !void {
    log.info("downloading {s}\n", .{url});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    var resp = std.ArrayList(u8).init(allocator);
    defer resp.deinit();
    var fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &resp },
        .max_append_size = 50 * 1024 * 1024,
    });
    if (fetch_res.status.class() != .success) {
        log.err("unable to fetch: HTTP {}", .{fetch_res.status});
        return error.FetchFailed;
    }
    log.info("finished\n", .{});

    const target_file = try std.fs.cwd().createFile(target_file_path, .{});
    try target_file.writeAll(resp.items);
}

fn isLinuxDesktopLike(tag: std.Target.Os.Tag) bool {
    return switch (tag) {
        .linux,
        .freebsd,
        .openbsd,
        .dragonfly,
        => true,
        else => false,
    };
}

// pub fn appendFlags(step: *std.Build.Step.Compile, flags: *std.ArrayList([]const u8), debug_symbols: bool, is_cpp: bool) !void {
//     if (debug_symbols) try flags.append("-g1") else try flags.append("-g0");
//     if (is_cpp) try flags.append("-std=c++17");
//     if (isLinuxDesktopLike(step.rootModuleTarget().os.tag)) {
//         step.root_module.addCMacro("DAWN_USE_X11", "1");
//         step.root_module.addCMacro("DAWN_USE_WAYLAND", "1");
//     }
// }

// fn linkLibDawnCommonDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     _ = b;
//     _ = options;
//     step.linkLibCpp();
//     if (step.rootModuleTarget().os.tag == .macos) {
//         @import("xcode_frameworks").addPaths(mod);
//         step.linkSystemLibrary("objc");
//         step.linkFramework("Foundation");
//     }
// }

// // Builds common sources; derived from src/common/BUILD.gn
// fn buildLibDawnCommon(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const target = step.rootModuleTarget();
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "dawn-common",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "dawn-common",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibDawnCommonDependencies(b, lib, lib.root_module, options);

//     if (target.os.tag == .linux) lib.linkLibrary(b.dependency("x11_headers", .{
//         .target = step.root_module.resolved_target.?,
//         .optimize = lib.root_module.optimize.?,
//     }).artifact("x11-headers"));

//     defineDawnEnableBackend(lib, options);

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(&.{
//         include("libs/dawn/src"),
//         include("libs/dawn/out/Release/gen/include"),
//         include("libs/dawn/out/Release/gen/src"),
//     });
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/dawn/common/",
//             "libs/dawn/out/Release/gen/src/dawn/common/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{
//             "test",
//             "benchmark",
//             "mock",
//             "WindowsUtils.cpp",
//         },
//     });

//     var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
//     if (target.os.tag == .macos) {
//         // TODO(build-system): pass system SDK options through
//         const abs_path = "libs/dawn/src/dawn/common/SystemUtils_mac.mm";
//         try cpp_sources.append(abs_path);
//     }
//     if (target.os.tag == .windows) {
//         const abs_path = "libs/dawn/src/dawn/common/WindowsUtils.cpp";
//         try cpp_sources.append(abs_path);
//     }

//     var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
//     try cpp_flags.appendSlice(flags.items);
//     try appendFlags(lib, &cpp_flags, options.debug, true);
//     lib.addCSourceFiles(.{ .files = cpp_sources.items, .flags = cpp_flags.items });
//     return lib;
// }

// fn linkLibDawnPlatformDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     _ = mod;
//     _ = b;
//     _ = options;
//     step.linkLibCpp();
// }

// // Build dawn platform sources; derived from src/dawn/platform/BUILD.gn
// fn buildLibDawnPlatform(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "dawn-platform",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "dawn-platform",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibDawnPlatformDependencies(b, lib, lib.root_module, options);

//     var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
//     try appendFlags(lib, &cpp_flags, options.debug, true);
//     try cpp_flags.appendSlice(&.{
//         include("libs/dawn/src"),
//         include("libs/dawn/include"),

//         include("libs/dawn/out/Release/gen/include"),
//     });

//     var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
//     inline for ([_][]const u8{
//         "src/dawn/platform/metrics/HistogramMacros.cpp",
//         "src/dawn/platform/tracing/EventTracer.cpp",
//         "src/dawn/platform/WorkerThread.cpp",
//         "src/dawn/platform/DawnPlatform.cpp",
//     }) |path| {
//         const abs_path = "libs/dawn/" ++ path;
//         try cpp_sources.append(abs_path);
//     }

//     lib.addCSourceFiles(.{ .files = cpp_sources.items, .flags = cpp_flags.items });
//     return lib;
// }

// fn defineDawnEnableBackend(step: *std.Build.Step.Compile, options: Options) void {
//     step.root_module.addCMacro("DAWN_ENABLE_BACKEND_NULL", "1");
//     // TODO: support the Direct3D 11 backend
//     // if (options.d3d11.?) step.root_module.addCMacro("DAWN_ENABLE_BACKEND_D3D11", "1");
//     if (options.d3d12.?) step.root_module.addCMacro("DAWN_ENABLE_BACKEND_D3D12", "1");
//     if (options.metal.?) step.root_module.addCMacro("DAWN_ENABLE_BACKEND_METAL", "1");
//     if (options.vulkan.?) step.root_module.addCMacro("DAWN_ENABLE_BACKEND_VULKAN", "1");
//     if (options.desktop_gl.?) {
//         step.root_module.addCMacro("DAWN_ENABLE_BACKEND_OPENGL", "1");
//         step.root_module.addCMacro("DAWN_ENABLE_BACKEND_DESKTOP_GL", "1");
//     }
//     if (options.opengl_es.?) {
//         step.root_module.addCMacro("DAWN_ENABLE_BACKEND_OPENGL", "1");
//         step.root_module.addCMacro("DAWN_ENABLE_BACKEND_OPENGLES", "1");
//     }
// }

// fn linkLibDawnNativeDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     step.linkLibCpp();
//     if (options.d3d12.?) {
//         step.linkLibrary(b.dependency("direct3d_headers", .{
//             .target = step.root_module.resolved_target.?,
//             .optimize = step.root_module.optimize.?,
//         }).artifact("direct3d-headers"));
//         @import("direct3d_headers").addLibraryPath(step);
//     }
//     if (options.metal.?) {
//         @import("xcode_frameworks").addPaths(mod);
//         step.linkSystemLibrary("objc");
//         step.linkFramework("Metal");
//         step.linkFramework("CoreGraphics");
//         step.linkFramework("Foundation");
//         step.linkFramework("IOKit");
//         step.linkFramework("IOSurface");
//         step.linkFramework("QuartzCore");
//     }
// }

// // Builds dawn native sources; derived from src/dawn/native/BUILD.gn
// fn buildLibDawnNative(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const target = step.rootModuleTarget();
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "dawn-native",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "dawn-native",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibDawnNativeDependencies(b, lib, lib.root_module, options);

//     if (options.vulkan.?) lib.linkLibrary(b.dependency("vulkan_headers", .{
//         .target = step.root_module.resolved_target.?,
//         .optimize = lib.root_module.optimize.?,
//     }).artifact("vulkan-headers"));
//     if (target.os.tag == .linux) lib.linkLibrary(b.dependency("x11_headers", .{
//         .target = step.root_module.resolved_target.?,
//         .optimize = lib.root_module.optimize.?,
//     }).artifact("x11-headers"));

//     // MacOS: this must be defined for macOS 13.3 and older.
//     // Critically, this MUST NOT be included as a -D__kernel_ptr_semantics flag. If it is,
//     // then this macro will not be defined even if `root_module.addCMacro` was also called!
//     lib.root_module.addCMacro("__kernel_ptr_semantics", "");

//     lib.root_module.addCMacro("_HRESULT_DEFINED", "");
//     lib.root_module.addCMacro("HRESULT", "long");
//     defineDawnEnableBackend(lib, options);

//     // TODO(build-system): make these optional
//     lib.root_module.addCMacro("TINT_BUILD_SPV_READER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_SPV_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_WGSL_READER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_WGSL_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_MSL_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_HLSL_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_GLSL_WRITER", "1");
//     lib.root_module.addCMacro("DAWN_NO_WINDOWS_UI", "1");

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(&.{
//         include("libs/dawn"),
//         include("libs/dawn/src"),
//         include("libs/dawn/include"),
//         include("libs/dawn/third_party/spirv-tools/src/include"),
//         include("libs/dawn/third_party/khronos"),

//         "-Wno-deprecated-declarations",
//         "-Wno-deprecated-builtins",
//         include("libs/dawn/third_party/abseil-cpp"),

//         include("libs/dawn/"),
//         include("libs/dawn/include/tint"),
//         include("libs/dawn/third_party/vulkan-tools/src/"),

//         include("libs/dawn/out/Release/gen/include"),
//         include("libs/dawn/out/Release/gen/src"),
//     });
//     if (options.d3d12.?) {
//         lib.root_module.addCMacro("DAWN_NO_WINDOWS_UI", "");
//         lib.root_module.addCMacro("__EMULATE_UUID", "");
//         lib.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "");
//         lib.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "");
//         lib.root_module.addCMacro("D3D10_ARBITRARY_HEADER_ORDERING", "");
//         lib.root_module.addCMacro("NOMINMAX", "");
//         try flags.appendSlice(&.{
//             "-Wno-nonportable-include-path",
//             "-Wno-extern-c-compat",
//             "-Wno-invalid-noreturn",
//             "-Wno-pragma-pack",
//             "-Wno-microsoft-template-shadow",
//             "-Wno-unused-command-line-argument",
//             "-Wno-microsoft-exception-spec",
//             "-Wno-implicit-exception-spec-mismatch",
//             "-Wno-unknown-attributes",
//             "-Wno-c++20-extensions",
//         });
//     }

//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/out/Release/gen/src/dawn/",
//             "libs/dawn/src/dawn/native/",
//             "libs/dawn/src/dawn/native/utils/",
//             "libs/dawn/src/dawn/native/stream/",
//         },
//         .flags = flags.items,
//         .excluding_contains = if (options.shared_libs) &.{
//             "test",
//             "benchmark",
//             "mock",
//             "SpirvValidation.cpp",
//             "X11Functions.cpp",
//             "dawn_proc.c",
//         } else &.{
//             "test",
//             "benchmark",
//             "mock",
//             "SpirvValidation.cpp",
//             "X11Functions.cpp",
//             "dawn_proc.c",
//         },
//     });

//     // dawn_native_gen
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/out/Release/gen/src/dawn/native/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "benchmark", "mock", "webgpu_dawn_native_proc.cpp" },
//     });

//     // TODO(build-system): could allow enable_vulkan_validation_layers here. See src/dawn/native/BUILD.gn
//     // TODO(build-system): allow use_angle here. See src/dawn/native/BUILD.gn
//     // TODO(build-system): could allow use_swiftshader here. See src/dawn/native/BUILD.gn

//     var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
//     if (options.d3d12.?) {
//         inline for ([_][]const u8{
//             "src/dawn/mingw_helpers.cpp",
//         }) |path| {
//             try cpp_sources.append(path);
//         }

//         try appendLangScannedSources(b, lib, .{
//             .rel_dirs = &.{
//                 "libs/dawn/src/dawn/native/d3d/",
//                 "libs/dawn/src/dawn/native/d3d12/",
//             },
//             .flags = flags.items,
//             .excluding_contains = &.{ "test", "benchmark", "mock" },
//         });
//     }
//     if (options.metal.?) {
//         try appendLangScannedSources(b, lib, .{
//             .objc = true,
//             .rel_dirs = &.{
//                 "libs/dawn/src/dawn/native/metal/",
//                 "libs/dawn/src/dawn/native/",
//             },
//             .flags = flags.items,
//             .excluding_contains = &.{ "test", "benchmark", "mock" },
//         });
//     }

//     if (isLinuxDesktopLike(target.os.tag)) {
//         inline for ([_][]const u8{
//             "src/dawn/native/X11Functions.cpp",
//         }) |path| {
//             const abs_path = "libs/dawn/" ++ path;
//             try cpp_sources.append(abs_path);
//         }
//     }

//     inline for ([_][]const u8{
//         "src/dawn/native/null/DeviceNull.cpp",
//     }) |path| {
//         const abs_path = "libs/dawn/" ++ path;
//         try cpp_sources.append(abs_path);
//     }

//     if (options.desktop_gl.? or options.vulkan.?) {
//         inline for ([_][]const u8{
//             "src/dawn/native/SpirvValidation.cpp",
//         }) |path| {
//             const abs_path = "libs/dawn/" ++ path;
//             try cpp_sources.append(abs_path);
//         }
//     }

//     if (options.desktop_gl.?) {
//         try appendLangScannedSources(b, lib, .{
//             .rel_dirs = &.{
//                 "libs/dawn/out/Release/gen/src/dawn/native/opengl/",
//                 "libs/dawn/src/dawn/native/opengl/",
//             },
//             .flags = flags.items,
//             .excluding_contains = &.{ "test", "benchmark", "mock" },
//         });
//     }

//     if (options.vulkan.?) {
//         try appendLangScannedSources(b, lib, .{
//             .rel_dirs = &.{
//                 "libs/dawn/src/dawn/native/vulkan/",
//             },
//             .flags = flags.items,
//             .excluding_contains = &.{ "test", "benchmark", "mock" },
//         });
//         try cpp_sources.append("libs/dawn/" ++ "src/dawn/native/vulkan/external_memory/MemoryService.cpp");
//         try cpp_sources.append("libs/dawn/" ++ "src/dawn/native/vulkan/external_memory/MemoryServiceImplementation.cpp");
//         try cpp_sources.append("libs/dawn/" ++ "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationDmaBuf.cpp");
//         try cpp_sources.append("libs/dawn/" ++ "src/dawn/native/vulkan/external_semaphore/SemaphoreService.cpp");
//         try cpp_sources.append("libs/dawn/" ++ "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementation.cpp");

//         if (isLinuxDesktopLike(target.os.tag)) {
//             inline for ([_][]const u8{
//                 "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationOpaqueFD.cpp",
//                 "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementationFD.cpp",
//             }) |path| {
//                 const abs_path = "libs/dawn/" ++ path;
//                 try cpp_sources.append(abs_path);
//             }
//         } else if (target.os.tag == .fuchsia) {
//             inline for ([_][]const u8{
//                 "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationZirconHandle.cpp",
//                 "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementationZirconHandle.cpp",
//             }) |path| {
//                 const abs_path = "libs/dawn/" ++ path;
//                 try cpp_sources.append(abs_path);
//             }
//         } else if (target.abi.isAndroid()) {
//             inline for ([_][]const u8{
//                 "src/dawn/native/vulkan/external_memory/MemoryServiceImplementationAHardwareBuffer.cpp",
//                 "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceImplementationFD.cpp",
//             }) |path| {
//                 const abs_path = "libs/dawn/" ++ path;
//                 try cpp_sources.append(abs_path);
//             }
//             lib.root_module.addCMacro("DAWN_USE_SYNC_FDS", "1");
//         }
//     }

//     // TODO(build-system): fuchsia: add is_fuchsia here from upstream source file

//     if (options.vulkan.?) {
//         // TODO(build-system): vulkan
//         //     if (enable_vulkan_validation_layers) {
//         //       defines += [
//         //         "DAWN_ENABLE_VULKAN_VALIDATION_LAYERS",
//         //         "DAWN_VK_DATA_DIR=\"$vulkan_data_subdir\"",
//         //       ]
//         //     }
//         //     if (enable_vulkan_loader) {
//         //       data_deps += [ "${dawn_vulkan_loader_dir}:libvulkan" ]
//         //       defines += [ "DAWN_ENABLE_VULKAN_LOADER" ]
//         //     }
//     }
//     // TODO(build-system): swiftshader
//     //     if (use_swiftshader) {
//     //       data_deps += [
//     //         "${dawn_swiftshader_dir}/src/Vulkan:icd_file",
//     //         "${dawn_swiftshader_dir}/src/Vulkan:swiftshader_libvulkan",
//     //       ]
//     //       defines += [
//     //         "DAWN_ENABLE_SWIFTSHADER",
//     //         "DAWN_SWIFTSHADER_VK_ICD_JSON=\"${swiftshader_icd_file_name}\"",
//     //       ]
//     //     }
//     //   }

//     if (options.opengl_es.?) {
//         // TODO(build-system): gles
//         //   if (use_angle) {
//         //     data_deps += [
//         //       "${dawn_angle_dir}:libEGL",
//         //       "${dawn_angle_dir}:libGLESv2",
//         //     ]
//         //   }
//         // }
//     }

//     inline for ([_][]const u8{
//         "src/dawn/native/null/NullBackend.cpp",
//     }) |path| {
//         const abs_path = "libs/dawn/" ++ path;
//         try cpp_sources.append(abs_path);
//     }

//     if (options.d3d12.?) {
//         inline for ([_][]const u8{
//             "src/dawn/native/d3d12/D3D12Backend.cpp",
//         }) |path| {
//             const abs_path = "libs/dawn/" ++ path;
//             try cpp_sources.append(abs_path);
//         }
//     }

//     var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
//     try cpp_flags.appendSlice(flags.items);
//     try appendFlags(lib, &cpp_flags, options.debug, true);
//     lib.addCSourceFiles(.{ .files = cpp_sources.items, .flags = cpp_flags.items });
//     return lib;
// }

// fn linkLibTintDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     _ = mod;
//     _ = b;
//     _ = options;
//     step.linkLibCpp();
// }

// // Builds tint sources; derived from src/tint/BUILD.gn
// fn buildLibTint(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const target = step.rootModuleTarget();
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "tint",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "tint",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibTintDependencies(b, lib, lib.root_module, options);

//     lib.root_module.addCMacro("_HRESULT_DEFINED", "");
//     lib.root_module.addCMacro("HRESULT", "long");

//     // TODO(build-system): make these optional
//     lib.root_module.addCMacro("TINT_BUILD_SPV_READER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_SPV_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_WGSL_READER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_WGSL_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_MSL_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_HLSL_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_GLSL_WRITER", "1");
//     lib.root_module.addCMacro("TINT_BUILD_SYNTAX_TREE_WRITER", "1");

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(&.{
//         include("libs/dawn/"),
//         include("libs/dawn/include/tint"),

//         // Required for TINT_BUILD_SPV_READER=1 and TINT_BUILD_SPV_WRITER=1, if specified
//         include("libs/dawn/third_party/vulkan-deps"),
//         include("libs/dawn/third_party/spirv-tools/src"),
//         include("libs/dawn/third_party/spirv-tools/src/include"),
//         include("libs/dawn/third_party/spirv-headers/src/include"),
//         include("libs/dawn/out/Release/gen/third_party/spirv-tools/src"),
//         include("libs/dawn/out/Release/gen/third_party/spirv-tools/src/include"),
//         include("libs/dawn/include"),
//         include("libs/dawn/third_party/abseil-cpp"),
//     });

//     // TODO: split out libtint builds, provide an example of building: src/tint/cmd

//     // libtint_core_all_src
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/tint",

//             "libs/dawn/src/tint/lang/core/",
//             "libs/dawn/src/tint/lang/core/constant/",
//             "libs/dawn/src/tint/lang/core/intrinsic/",
//             "libs/dawn/src/tint/lang/core/ir/",
//             "libs/dawn/src/tint/lang/core/ir/transform/",
//             "libs/dawn/src/tint/lang/core/type/",

//             "libs/dawn/src/tint/utils/containers",
//             // "libs/dawn/src/tint/utils/debug",
//             "libs/dawn/src/tint/utils/diagnostic",
//             // "libs/dawn/src/tint/utils/generator",
//             "libs/dawn/src/tint/utils/ice",
//             // "libs/dawn/src/tint/utils/id",
//             "libs/dawn/src/tint/utils/macros",
//             "libs/dawn/src/tint/utils/math",
//             "libs/dawn/src/tint/utils/memory",
//             // "libs/dawn/src/tint/utils/reflection",
//             // "libs/dawn/src/tint/utils/result",
//             "libs/dawn/src/tint/utils/rtti",
//             "libs/dawn/src/tint/utils/strconv",
//             "libs/dawn/src/tint/utils/symbol",
//             "libs/dawn/src/tint/utils/templates",
//             "libs/dawn/src/tint/utils/text",
//             // "libs/dawn/src/tint/utils/traits",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "bench", "printer_windows", "printer_posix", "printer_other", "glsl.cc" },
//     });

//     var cpp_sources = std.ArrayList([]const u8).init(b.allocator);

//     if (target.os.tag == .windows) {
//         // try cpp_sources.append("libs/dawn/src/tint/utils/diagnostic/printer_windows.cc");
//     } else if (target.os.tag.isDarwin() or isLinuxDesktopLike(target.os.tag)) {
//         try cpp_sources.append("libs/dawn/src/tint/utils/diagnostic/printer_posix.cc");
//     } else {
//         try cpp_sources.append("libs/dawn/src/tint/utils/diagnostic/printer_other.cc");
//     }

//     // libtint_sem_src
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/tint/lang/wgsl/sem/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "benchmark" },
//     });

//     // spirv
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/tint/lang/spirv/reader",
//             "libs/dawn/src/tint/lang/spirv/reader/ast_parser",
//             "libs/dawn/src/tint/lang/spirv/writer",
//             // "libs/dawn/src/tint/lang/spirv/writer/ast_printer",
//             "libs/dawn/src/tint/lang/spirv/writer/common",
//             "libs/dawn/src/tint/lang/spirv/writer/printer",
//             "libs/dawn/src/tint/lang/spirv/writer/raise",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "bench" },
//     });

//     // wgsl
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/tint/lang/wgsl/reader",
//             "libs/dawn/src/tint/lang/wgsl/reader/parser",
//             "libs/dawn/src/tint/lang/wgsl/reader/program_to_ir",
//             "libs/dawn/src/tint/lang/wgsl/ast",
//             // "libs/dawn/src/tint/lang/wgsl/ast/transform",
//             // "libs/dawn/src/tint/lang/wgsl/helpers",
//             "libs/dawn/src/tint/lang/wgsl/inspector",
//             "libs/dawn/src/tint/lang/wgsl/program",
//             "libs/dawn/src/tint/lang/wgsl/resolver",
//             "libs/dawn/src/tint/lang/wgsl/writer",
//             "libs/dawn/src/tint/lang/wgsl/writer/ast_printer",
//             "libs/dawn/src/tint/lang/wgsl/writer/ir_to_program",
//             "libs/dawn/src/tint/lang/wgsl/writer/syntax_tree_printer",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "bench" },
//     });

//     // msl
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/tint/lang/msl/writer",
//             // "libs/dawn/src/tint/lang/msl/writer/ast_printer",
//             "libs/dawn/src/tint/lang/msl/writer/common",
//             "libs/dawn/src/tint/lang/msl/writer/printer",
//             "libs/dawn/src/tint/lang/msl/validate",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "bench" },
//     });

//     // hlsl
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/tint/lang/hlsl/writer",
//             // "libs/dawn/src/tint/lang/hlsl/writer/ast_printer",
//             "libs/dawn/src/tint/lang/hlsl/writer/common",
//             "libs/dawn/src/tint/lang/hlsl/validate",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "bench" },
//     });

//     // glsl
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/src/tint/lang/glsl/",
//             "libs/dawn/src/tint/lang/glsl/writer",
//             // "libs/dawn/src/tint/lang/glsl/writer/ast_printer",
//             "libs/dawn/src/tint/lang/glsl/writer/common",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "bench" },
//     });

//     var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
//     try cpp_flags.appendSlice(flags.items);
//     try appendFlags(lib, &cpp_flags, options.debug, true);
//     lib.addCSourceFiles(.{ .files = cpp_sources.items, .flags = cpp_flags.items });
//     return lib;
// }

// fn linkLibSPIRVToolsDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     _ = mod;
//     _ = b;
//     _ = options;
//     step.linkLibCpp();
// }

// // Builds third_party/spirv-tools sources; derived from third_party/spirv-tools/src/BUILD.gn
// fn buildLibSPIRVTools(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "spirv-tools",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "spirv-tools",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibSPIRVToolsDependencies(b, lib, lib.root_module, options);

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(&.{
//         include("libs/dawn"),
//         include("libs/dawn/third_party/spirv-tools/src"),
//         include("libs/dawn/third_party/spirv-tools/src/include"),
//         include("libs/dawn/third_party/spirv-headers/src/include"),
//         include("libs/dawn/out/Release/gen/third_party/spirv-tools/src"),
//         include("libs/dawn/out/Release/gen/third_party/spirv-tools/src/include"),
//         include("libs/dawn/third_party/spirv-headers/src/include/spirv/unified1"),
//     });

//     // spvtools
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/third_party/spirv-tools/src/source/",
//             "libs/dawn/third_party/spirv-tools/src/source/util/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "benchmark" },
//     });

//     // spvtools_val
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/third_party/spirv-tools/src/source/val/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "benchmark" },
//     });

//     // spvtools_opt
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/third_party/spirv-tools/src/source/opt/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "benchmark" },
//     });

//     // spvtools_link
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/third_party/spirv-tools/src/source/link/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "benchmark" },
//     });
//     return lib;
// }

// fn linkLibAbseilCppDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     _ = b;
//     _ = options;
//     step.linkLibCpp();
//     const target = step.rootModuleTarget();
//     if (target.os.tag == .macos) {
//         @import("xcode_frameworks").addPaths(mod);
//         step.linkSystemLibrary("objc");
//         step.linkFramework("CoreFoundation");
//     }
//     if (target.os.tag == .windows) step.linkSystemLibrary("bcrypt");
// }

// // Builds third_party/abseil sources; derived from:
// //
// // ```
// // $ find third_party/abseil-cpp/absl | grep '\.cc' | grep -v 'test' | grep -v 'benchmark' | grep -v gaussian_distribution_gentables | grep -v print_hash_of | grep -v chi_square
// // ```
// //
// fn buildLibAbseilCpp(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const target = step.rootModuleTarget();
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "abseil",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "abseil",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibAbseilCppDependencies(b, lib, lib.root_module, options);

//     // musl needs this defined in order for off64_t to be a type, which abseil-cpp uses
//     lib.root_module.addCMacro("_FILE_OFFSET_BITS", "64");
//     lib.root_module.addCMacro("_LARGEFILE64_SOURCE", "");

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(&.{
//         include("libs/dawn"),
//         include("libs/dawn/third_party/abseil-cpp"),
//         "-Wno-deprecated-declarations",
//         "-Wno-deprecated-builtins",
//     });
//     if (target.os.tag == .windows) {
//         lib.root_module.addCMacro("ABSL_FORCE_THREAD_IDENTITY_MODE", "2");
//         lib.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "");
//         lib.root_module.addCMacro("D3D10_ARBITRARY_HEADER_ORDERING", "");
//         lib.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "");
//         lib.root_module.addCMacro("NOMINMAX", "");
//         try flags.append(include("src/dawn/zig_mingw_pthread"));
//     }

//     // absl
//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/third_party/abseil-cpp/absl/strings/",
//             "libs/dawn/third_party/abseil-cpp/absl/strings/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/strings/internal/str_format/",
//             "libs/dawn/third_party/abseil-cpp/absl/types/",
//             "libs/dawn/third_party/abseil-cpp/absl/flags/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/flags/",
//             "libs/dawn/third_party/abseil-cpp/absl/synchronization/",
//             "libs/dawn/third_party/abseil-cpp/absl/synchronization/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/hash/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/debugging/",
//             "libs/dawn/third_party/abseil-cpp/absl/debugging/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/status/",
//             "libs/dawn/third_party/abseil-cpp/absl/time/internal/cctz/src/",
//             "libs/dawn/third_party/abseil-cpp/absl/time/",
//             "libs/dawn/third_party/abseil-cpp/absl/container/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/numeric/",
//             "libs/dawn/third_party/abseil-cpp/absl/random/",
//             "libs/dawn/third_party/abseil-cpp/absl/random/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/base/internal/",
//             "libs/dawn/third_party/abseil-cpp/absl/base/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "_test", "_testing", "benchmark", "print_hash_of.cc", "gaussian_distribution_gentables.cc" },
//     });
//     return lib;
// }

// fn linkLibDawnWireDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     _ = mod;
//     _ = b;
//     _ = options;
//     step.linkLibCpp();
// }

// // Buids dawn wire sources; derived from src/dawn/wire/BUILD.gn
// fn buildLibDawnWire(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "dawn-wire",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "dawn-wire",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibDawnWireDependencies(b, lib, lib.root_module, options);

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(&.{
//         include("libs/dawn"),
//         include("libs/dawn/src"),
//         include("libs/dawn/include"),
//         include("libs/dawn/out/Release/gen/include"),
//         include("libs/dawn/out/Release/gen/src"),
//     });

//     try appendLangScannedSources(b, lib, .{
//         .rel_dirs = &.{
//             "libs/dawn/out/Release/gen/src/dawn/wire/",
//             "libs/dawn/out/Release/gen/src/dawn/wire/client/",
//             "libs/dawn/out/Release/gen/src/dawn/wire/server/",
//             "libs/dawn/src/dawn/wire/",
//             "libs/dawn/src/dawn/wire/client/",
//             "libs/dawn/src/dawn/wire/server/",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{ "test", "benchmark", "mock" },
//     });
//     return lib;
// }

// fn linkLibDxcompilerDependencies(b: *std.Build, step: *std.Build.Step.Compile, mod: *std.Build.Module, options: Options) void {
//     _ = mod;
//     if (options.d3d12.?) {
//         step.linkLibCpp();
//         step.linkLibrary(b.dependency("direct3d_headers", .{
//             .target = step.root_module.resolved_target.?,
//             .optimize = step.root_module.optimize.?,
//         }).artifact("direct3d-headers"));
//         @import("direct3d_headers").addLibraryPath(step);
//         step.linkSystemLibrary("oleaut32");
//         step.linkSystemLibrary("ole32");
//         step.linkSystemLibrary("dbghelp");
//     }
// }

// // Buids dxcompiler sources; derived from libs/DirectXShaderCompiler/CMakeLists.txt
// fn buildLibDxcompiler(b: *std.Build, step: *std.Build.Step.Compile, options: Options) !*std.Build.Step.Compile {
//     const lib = if (!options.separate_libs) step else if (options.shared_libs) b.addSharedLibrary(.{
//         .name = "dxcompiler",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     }) else b.addStaticLibrary(.{
//         .name = "dxcompiler",
//         .target = step.root_module.resolved_target.?,
//         .optimize = if (options.debug) .Debug else .ReleaseFast,
//     });
//     if (options.install_libs) b.installArtifact(lib);
//     linkLibDxcompilerDependencies(b, lib, lib.root_module, options);

//     lib.root_module.addCMacro("UNREFERENCED_PARAMETER(x)", "");
//     lib.root_module.addCMacro("MSFT_SUPPORTS_CHILD_PROCESSES", "1");
//     lib.root_module.addCMacro("HAVE_LIBPSAPI", "1");
//     lib.root_module.addCMacro("HAVE_LIBSHELL32", "1");
//     lib.root_module.addCMacro("LLVM_ON_WIN32", "1");

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(&.{
//         include("libs/"),
//         include("libs/DirectXShaderCompiler/include/llvm/llvm_assert"),
//         include("libs/DirectXShaderCompiler/include"),
//         include("libs/DirectXShaderCompiler/build/include"),
//         include("libs/DirectXShaderCompiler/build/lib/HLSL"),
//         include("libs/DirectXShaderCompiler/build/lib/DxilPIXPasses"),
//         include("libs/DirectXShaderCompiler/build/include"),
//         "-Wno-inconsistent-missing-override",
//         "-Wno-missing-exception-spec",
//         "-Wno-switch",
//         "-Wno-deprecated-declarations",
//         "-Wno-macro-redefined", // regex2.h and regcomp.c requires this for OUT redefinition
//     });

//     try appendLangScannedSources(b, lib, .{
//         .debug_symbols = false,
//         .rel_dirs = &.{
//             "libs/DirectXShaderCompiler/lib/Analysis/IPA",
//             "libs/DirectXShaderCompiler/lib/Analysis",
//             "libs/DirectXShaderCompiler/lib/AsmParser",
//             "libs/DirectXShaderCompiler/lib/Bitcode/Writer",
//             "libs/DirectXShaderCompiler/lib/DxcBindingTable",
//             "libs/DirectXShaderCompiler/lib/DxcSupport",
//             "libs/DirectXShaderCompiler/lib/DxilContainer",
//             "libs/DirectXShaderCompiler/lib/DxilPIXPasses",
//             "libs/DirectXShaderCompiler/lib/DxilRootSignature",
//             "libs/DirectXShaderCompiler/lib/DXIL",
//             "libs/DirectXShaderCompiler/lib/DxrFallback",
//             "libs/DirectXShaderCompiler/lib/HLSL",
//             "libs/DirectXShaderCompiler/lib/IRReader",
//             "libs/DirectXShaderCompiler/lib/IR",
//             "libs/DirectXShaderCompiler/lib/Linker",
//             "libs/DirectXShaderCompiler/lib/Miniz",
//             "libs/DirectXShaderCompiler/lib/Option",
//             "libs/DirectXShaderCompiler/lib/PassPrinters",
//             "libs/DirectXShaderCompiler/lib/Passes",
//             "libs/DirectXShaderCompiler/lib/ProfileData",
//             "libs/DirectXShaderCompiler/lib/Target",
//             "libs/DirectXShaderCompiler/lib/Transforms/InstCombine",
//             "libs/DirectXShaderCompiler/lib/Transforms/IPO",
//             "libs/DirectXShaderCompiler/lib/Transforms/Scalar",
//             "libs/DirectXShaderCompiler/lib/Transforms/Utils",
//             "libs/DirectXShaderCompiler/lib/Transforms/Vectorize",
//         },
//         .flags = flags.items,
//     });

//     try appendLangScannedSources(b, lib, .{
//         .debug_symbols = false,
//         .rel_dirs = &.{
//             "libs/DirectXShaderCompiler/lib/Support",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{
//             "DynamicLibrary.cpp", // ignore, HLSL_IGNORE_SOURCES
//             "PluginLoader.cpp", // ignore, HLSL_IGNORE_SOURCES
//             "Path.cpp", // ignore, LLVM_INCLUDE_TESTS
//             "DynamicLibrary.cpp", // ignore
//         },
//     });

//     try appendLangScannedSources(b, lib, .{
//         .debug_symbols = false,
//         .rel_dirs = &.{
//             "libs/DirectXShaderCompiler/lib/Bitcode/Reader",
//         },
//         .flags = flags.items,
//         .excluding_contains = &.{
//             "BitReader.cpp", // ignore
//         },
//     });
//     return lib;
// }

// fn appendLangScannedSources(
//     b: *std.Build,
//     step: *std.Build.Step.Compile,
//     args: struct {
//         debug_symbols: bool = false,
//         flags: []const []const u8,
//         rel_dirs: []const []const u8 = &.{},
//         objc: bool = false,
//         excluding: []const []const u8 = &.{},
//         excluding_contains: []const []const u8 = &.{},
//     },
// ) !void {
//     var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
//     try cpp_flags.appendSlice(args.flags);
//     try appendFlags(step, &cpp_flags, args.debug_symbols, true);
//     const cpp_extensions: []const []const u8 = if (args.objc) &.{".mm"} else &.{ ".cpp", ".cc" };
//     try appendScannedSources(b, step, .{
//         .flags = cpp_flags.items,
//         .rel_dirs = args.rel_dirs,
//         .extensions = cpp_extensions,
//         .excluding = args.excluding,
//         .excluding_contains = args.excluding_contains,
//     });

//     var flags = std.ArrayList([]const u8).init(b.allocator);
//     try flags.appendSlice(args.flags);
//     try appendFlags(step, &flags, args.debug_symbols, false);
//     const c_extensions: []const []const u8 = if (args.objc) &.{".m"} else &.{".c"};
//     try appendScannedSources(b, step, .{
//         .flags = flags.items,
//         .rel_dirs = args.rel_dirs,
//         .extensions = c_extensions,
//         .excluding = args.excluding,
//         .excluding_contains = args.excluding_contains,
//     });
// }

// fn appendScannedSources(b: *std.Build, step: *std.Build.Step.Compile, args: struct {
//     flags: []const []const u8,
//     rel_dirs: []const []const u8 = &.{},
//     extensions: []const []const u8,
//     excluding: []const []const u8 = &.{},
//     excluding_contains: []const []const u8 = &.{},
// }) !void {
//     var sources = std.ArrayList([]const u8).init(b.allocator);
//     for (args.rel_dirs) |rel_dir| {
//         try scanSources(b, &sources, rel_dir, args.extensions, args.excluding, args.excluding_contains);
//     }
//     step.addCSourceFiles(.{ .files = sources.items, .flags = args.flags });
// }

// /// Scans rel_dir for sources ending with one of the provided extensions, excluding relative paths
// /// listed in the excluded list.
// /// Results are appended to the dst ArrayList.
// fn scanSources(
//     b: *std.Build,
//     dst: *std.ArrayList([]const u8),
//     rel_dir: []const u8,
//     extensions: []const []const u8,
//     excluding: []const []const u8,
//     excluding_contains: []const []const u8,
// ) !void {
//     const abs_dir = try std.fs.path.join(b.allocator, &.{ sdkPath("/"), rel_dir });
//     var dir = std.fs.openDirAbsolute(abs_dir, .{ .iterate = true }) catch |err| {
//         std.log.err("mach: error: failed to open: {s}", .{abs_dir});
//         return err;
//     };
//     defer dir.close();
//     var dir_it = dir.iterate();
//     while (try dir_it.next()) |entry| {
//         if (entry.kind != .file) continue;
//         const rel_path = try std.fs.path.join(b.allocator, &.{ rel_dir, entry.name });

//         const allowed_extension = blk: {
//             const ours = std.fs.path.extension(entry.name);
//             for (extensions) |ext| {
//                 if (std.mem.eql(u8, ours, ext)) break :blk true;
//             }
//             break :blk false;
//         };
//         if (!allowed_extension) continue;

//         const excluded = blk: {
//             for (excluding) |excluded| {
//                 if (std.mem.eql(u8, entry.name, excluded)) break :blk true;
//             }
//             break :blk false;
//         };
//         if (excluded) continue;

//         const excluded_contains = blk: {
//             for (excluding_contains) |contains| {
//                 if (std.mem.containsAtLeast(u8, entry.name, 1, contains)) break :blk true;
//             }
//             break :blk false;
//         };
//         if (excluded_contains) continue;

//         try dst.append(rel_path);
//     }
// }

inline fn include(rel: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc.?, "-I{s}", .{sdkPath(rel)}) catch unreachable;
}

inline fn sdkPath(suffix: []const u8) []const u8 {
    return std.fs.path.join(alloc.?, &.{ cwd_path.?, suffix }) catch unreachable;
}

inline fn prepPathStrings(allocator: std.mem.Allocator) !void {
    alloc = allocator;
    cwd_path = try std.fs.cwd().realpath(".", &cwd_name_buf);
}

var alloc: ?std.mem.Allocator = null;
var cwd_name_buf: [std.fs.MAX_NAME_BYTES]u8 = .{0} ** std.fs.MAX_NAME_BYTES;
var cwd_path: ?[]const u8 = null;
