path: []const u8,
data: []const u8,
index: File.Index,

header: ?macho.mach_header_64 = null,
symtab: std.MultiArrayList(Nlist) = .{},
strtab: std.ArrayListUnmanaged(u8) = .{},
id: ?Id = null,
ordinal: u16 = 0,

symbols: std.ArrayListUnmanaged(Symbol.Index) = .{},
dependents: std.ArrayListUnmanaged(Id) = .{},
platform: ?MachO.Options.Platform = null,

needed: bool,
weak: bool,
alive: bool,

output_symtab_ctx: MachO.SymtabCtx = .{},

pub fn deinit(self: *Dylib, allocator: Allocator) void {
    self.symtab.deinit(allocator);
    self.strtab.deinit(allocator);
    if (self.id) |*id| id.deinit(allocator);
    self.symbols.deinit(allocator);
    for (self.dependents.items) |*id| {
        id.deinit(allocator);
    }
    self.dependents.deinit(allocator);
}

pub fn parse(self: *Dylib, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    var stream = std.io.fixedBufferStream(self.data);
    const reader = stream.reader();

    log.debug("parsing dylib from binary", .{});

    self.header = try reader.readStruct(macho.mach_header_64);

    const lc_id = self.getLoadCommand(.ID_DYLIB) orelse
        return macho_file.base.fatal("{s}: missing LC_ID_DYLIB load command", .{self.path});
    self.id = try Id.fromLoadCommand(gpa, lc_id.cast(macho.dylib_command).?, lc_id.getDylibPathName());

    var it = LoadCommandIterator{
        .ncmds = self.header.?.ncmds,
        .buffer = self.data[@sizeOf(macho.mach_header_64)..][0..self.header.?.sizeofcmds],
    };
    while (it.next()) |cmd| switch (cmd.cmd()) {
        .REEXPORT_DYLIB => if (self.header.?.flags & macho.MH_NO_REEXPORTED_DYLIBS == 0) {
            const id = try Id.fromLoadCommand(gpa, cmd.cast(macho.dylib_command).?, cmd.getDylibPathName());
            try self.dependents.append(gpa, id);
        },
        .DYLD_INFO_ONLY => {
            const dyld_cmd = cmd.cast(macho.dyld_info_command).?;
            const data = self.data[dyld_cmd.export_off..][0..dyld_cmd.export_size];
            try self.parseTrie(data, macho_file);
        },
        .DYLD_EXPORTS_TRIE => {
            const ld_cmd = cmd.cast(macho.linkedit_data_command).?;
            const data = self.data[ld_cmd.dataoff..][0..ld_cmd.datasize];
            try self.parseTrie(data, macho_file);
        },
        else => {},
    };

    try self.initSymbols(macho_file);
    self.initPlatform();
}

const TrieIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn getStream(it: *TrieIterator) std.io.FixedBufferStream([]const u8) {
        return std.io.fixedBufferStream(it.data[it.pos..]);
    }

    fn readULEB128(it: *TrieIterator) !u64 {
        var stream = it.getStream();
        var creader = std.io.countingReader(stream.reader());
        const reader = creader.reader();
        const value = try std.leb.readULEB128(u64, reader);
        it.pos += creader.bytes_read;
        return value;
    }

    fn readString(it: *TrieIterator) ![:0]const u8 {
        var stream = it.getStream();
        const reader = stream.reader();

        var count: usize = 0;
        while (true) : (count += 1) {
            const byte = try reader.readByte();
            if (byte == 0) break;
        }

        const str = @as([*:0]const u8, @ptrCast(it.data.ptr + it.pos))[0..count :0];
        it.pos += count + 1;
        return str;
    }

    fn readByte(it: *TrieIterator) !u8 {
        var stream = it.getStream();
        const value = try stream.reader().readByte();
        it.pos += 1;
        return value;
    }
};

const Export = struct {
    name: []const u8,
    flags: u64,
};

fn parseTrieNode(it: *TrieIterator, arena: Allocator, prefix: []const u8, exports: *std.ArrayList(Export)) !void {
    const size = try it.readULEB128();
    if (size > 0) {
        const flags = try it.readULEB128();
        if (flags & macho.EXPORT_SYMBOL_FLAGS_REEXPORT != 0) {
            _ = try it.readULEB128(); // dylib ordinal
            const name = try arena.dupe(u8, try it.readString());
            try exports.append(.{
                .name = if (name.len > 0) name else prefix,
                .flags = flags,
            });
        } else if (flags & macho.EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER != 0) {
            _ = try it.readULEB128(); // stub offset
            _ = try it.readULEB128(); // resolver offset
            try exports.append(.{
                .name = prefix,
                .flags = flags,
            });
        } else {
            _ = try it.readULEB128(); // VM offset
            try exports.append(.{
                .name = prefix,
                .flags = flags,
            });
        }
    }

    const nedges = try it.readByte();

    for (0..nedges) |_| {
        const label = try it.readString();
        const off = try it.readULEB128();
        const prefix_label = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, label });
        const curr = it.pos;
        it.pos = off;
        try parseTrieNode(it, arena, prefix_label, exports);
        it.pos = curr;
    }
}

fn parseTrie(self: *Dylib, data: []const u8, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var exports = std.ArrayList(Export).init(gpa);
    defer exports.deinit();

    var it: TrieIterator = .{ .data = data };
    try parseTrieNode(&it, arena.allocator(), "", &exports);

    for (exports.items) |exp| {
        const sym_index = if (exp.flags & macho.EXPORT_SYMBOL_FLAGS_WEAK_DEFINITION != 0)
            try self.addWeak(exp.name, macho_file)
        else
            try self.addGlobal(exp.name, macho_file);

        switch (exp.flags & macho.EXPORT_SYMBOL_FLAGS_KIND_MASK) {
            macho.EXPORT_SYMBOL_FLAGS_KIND_REGULAR => {},
            macho.EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE => {
                self.symtab.items(.nlist)[sym_index].n_type = macho.N_EXT | macho.N_ABS;
            },
            macho.EXPORT_SYMBOL_FLAGS_KIND_THREAD_LOCAL => {
                self.symtab.items(.tlv)[sym_index] = true;
            },
            else => unreachable, // TODO error
        }
    }
}

pub fn parseTbd(
    self: *Dylib,
    cpu_arch: std.Target.Cpu.Arch,
    platform: ?MachO.Options.Platform,
    lib_stub: LibStub,
    macho_file: *MachO,
) !void {
    const gpa = macho_file.base.allocator;

    log.debug("parsing dylib from stub", .{});

    const umbrella_lib = lib_stub.inner[0];

    {
        var id = try Id.default(gpa, umbrella_lib.installName());
        if (umbrella_lib.currentVersion()) |version| {
            try id.parseCurrentVersion(version);
        }
        if (umbrella_lib.compatibilityVersion()) |version| {
            try id.parseCompatibilityVersion(version);
        }
        self.id = id;
    }

    var umbrella_libs = std.StringHashMap(void).init(gpa);
    defer umbrella_libs.deinit();

    log.debug("  (install_name '{s}')", .{umbrella_lib.installName()});

    self.platform = platform orelse .{
        .platform = .MACOS,
        .version = .{ .value = 0 },
    };

    var matcher = try TargetMatcher.init(gpa, cpu_arch, self.platform.?.platform);
    defer matcher.deinit();

    for (lib_stub.inner, 0..) |elem, stub_index| {
        if (!(try matcher.matchesTargetTbd(elem))) continue;

        if (stub_index > 0) {
            // TODO I thought that we could switch on presence of `parent-umbrella` map;
            // however, turns out `libsystem_notify.dylib` is fully reexported by `libSystem.dylib`
            // BUT does not feature a `parent-umbrella` map as the only sublib. Apple's bug perhaps?
            try umbrella_libs.put(elem.installName(), {});
        }

        switch (elem) {
            .v3 => |stub| {
                if (stub.exports) |exports| {
                    for (exports) |exp| {
                        if (!matcher.matchesArch(exp.archs)) continue;

                        if (exp.symbols) |symbols| {
                            for (symbols) |sym_name| {
                                _ = try self.addGlobal(sym_name, macho_file);
                            }
                        }

                        if (exp.weak_symbols) |symbols| {
                            for (symbols) |sym_name| {
                                _ = try self.addWeak(sym_name, macho_file);
                            }
                        }

                        if (exp.objc_classes) |objc_classes| {
                            for (objc_classes) |class_name| {
                                try self.addObjCClass(class_name, macho_file);
                            }
                        }

                        if (exp.objc_ivars) |objc_ivars| {
                            for (objc_ivars) |ivar| {
                                try self.addObjCIVar(ivar, macho_file);
                            }
                        }

                        if (exp.objc_eh_types) |objc_eh_types| {
                            for (objc_eh_types) |eht| {
                                try self.addObjCEhType(eht, macho_file);
                            }
                        }

                        if (exp.re_exports) |re_exports| {
                            for (re_exports) |lib| {
                                if (umbrella_libs.contains(lib)) continue;

                                log.debug("  (found re-export '{s}')", .{lib});

                                const dep_id = try Id.default(gpa, lib);
                                try self.dependents.append(gpa, dep_id);
                            }
                        }
                    }
                }
            },
            .v4 => |stub| {
                if (stub.exports) |exports| {
                    for (exports) |exp| {
                        if (!matcher.matchesTarget(exp.targets)) continue;

                        if (exp.symbols) |symbols| {
                            for (symbols) |sym_name| {
                                _ = try self.addGlobal(sym_name, macho_file);
                            }
                        }

                        if (exp.weak_symbols) |symbols| {
                            for (symbols) |sym_name| {
                                _ = try self.addWeak(sym_name, macho_file);
                            }
                        }

                        if (exp.objc_classes) |classes| {
                            for (classes) |sym_name| {
                                try self.addObjCClass(sym_name, macho_file);
                            }
                        }

                        if (exp.objc_ivars) |objc_ivars| {
                            for (objc_ivars) |ivar| {
                                try self.addObjCIVar(ivar, macho_file);
                            }
                        }

                        if (exp.objc_eh_types) |objc_eh_types| {
                            for (objc_eh_types) |eht| {
                                try self.addObjCEhType(eht, macho_file);
                            }
                        }
                    }
                }

                if (stub.reexports) |reexports| {
                    for (reexports) |reexp| {
                        if (!matcher.matchesTarget(reexp.targets)) continue;

                        if (reexp.symbols) |symbols| {
                            for (symbols) |sym_name| {
                                _ = try self.addGlobal(sym_name, macho_file);
                            }
                        }

                        if (reexp.weak_symbols) |symbols| {
                            for (symbols) |sym_name| {
                                _ = try self.addWeak(sym_name, macho_file);
                            }
                        }

                        if (reexp.objc_classes) |classes| {
                            for (classes) |sym_name| {
                                try self.addObjCClass(sym_name, macho_file);
                            }
                        }

                        if (reexp.objc_ivars) |objc_ivars| {
                            for (objc_ivars) |ivar| {
                                try self.addObjCIVar(ivar, macho_file);
                            }
                        }

                        if (reexp.objc_eh_types) |objc_eh_types| {
                            for (objc_eh_types) |eht| {
                                try self.addObjCEhType(eht, macho_file);
                            }
                        }
                    }
                }

                if (stub.objc_classes) |classes| {
                    for (classes) |sym_name| {
                        try self.addObjCClass(sym_name, macho_file);
                    }
                }

                if (stub.objc_ivars) |objc_ivars| {
                    for (objc_ivars) |ivar| {
                        try self.addObjCIVar(ivar, macho_file);
                    }
                }

                if (stub.objc_eh_types) |objc_eh_types| {
                    for (objc_eh_types) |eht| {
                        try self.addObjCEhType(eht, macho_file);
                    }
                }
            },
        }
    }

    // For V4, we add dependent libs in a separate pass since some stubs such as libSystem include
    // re-exports directly in the stub file.
    for (lib_stub.inner) |elem| {
        if (elem == .v3) continue;
        const stub = elem.v4;

        if (stub.reexported_libraries) |reexports| {
            for (reexports) |reexp| {
                if (!matcher.matchesTarget(reexp.targets)) continue;

                for (reexp.libraries) |lib| {
                    if (umbrella_libs.contains(lib)) continue;

                    log.debug("  (found re-export '{s}')", .{lib});

                    const dep_id = try Id.default(gpa, lib);
                    try self.dependents.append(gpa, dep_id);
                }
            }
        }
    }

    try self.initSymbols(macho_file);
}

fn addObjCClass(self: *Dylib, name: []const u8, macho_file: *MachO) !void {
    try self.addObjCGlobal("_OBJC_CLASS", name, macho_file);
    try self.addObjCGlobal("_OBJC_METACLASS_", name, macho_file);
}

fn addObjCIVar(self: *Dylib, name: []const u8, macho_file: *MachO) !void {
    try self.addObjCGlobal("_OBJC_IVAR_", name, macho_file);
}

fn addObjCEhType(self: *Dylib, name: []const u8, macho_file: *MachO) !void {
    try self.addObjCGlobal("_OBJC_EHTYPE_", name, macho_file);
}

fn addObjCGlobal(self: *Dylib, comptime prefix: []const u8, name: []const u8, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    const full_name = try std.fmt.allocPrint(gpa, prefix ++ "$_{s}", .{name});
    defer gpa.free(full_name);
    _ = try self.addGlobal(full_name, macho_file);
}

fn addGlobal(self: *Dylib, name: []const u8, macho_file: *MachO) !Symbol.Index {
    const gpa = macho_file.base.allocator;
    const index = @as(Symbol.Index, @intCast(try self.symtab.addOne(gpa)));
    self.symtab.set(index, .{ .nlist = .{
        .n_strx = try self.insertString(gpa, name),
        .n_type = macho.N_EXT | macho.N_SECT,
        .n_value = 0,
        .n_desc = 0,
        .n_sect = 0,
    } });
    return index;
}

fn addWeak(self: *Dylib, name: []const u8, macho_file: *MachO) !Symbol.Index {
    const index = try self.addGlobal(name, macho_file);
    self.symtab.items(.nlist)[index].n_desc |= macho.N_WEAK_DEF;
    return index;
}

fn initSymbols(self: *Dylib, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    const slice = self.symtab.slice();

    try self.symbols.ensureTotalCapacityPrecise(gpa, slice.items(.nlist).len);

    for (slice.items(.nlist)) |sym| {
        const name = self.getString(sym.n_strx);
        const off = try macho_file.string_intern.insert(gpa, name);
        const gop = try macho_file.getOrCreateGlobal(off);
        self.symbols.addOneAssumeCapacity().* = gop.index;
    }
}

fn initPlatform(self: *Dylib) void {
    var it = LoadCommandIterator{
        .ncmds = self.header.?.ncmds,
        .buffer = self.data[@sizeOf(macho.mach_header_64)..][0..self.header.?.sizeofcmds],
    };
    self.platform = while (it.next()) |cmd| {
        switch (cmd.cmd()) {
            .BUILD_VERSION,
            .VERSION_MIN_MACOSX,
            .VERSION_MIN_IPHONEOS,
            .VERSION_MIN_TVOS,
            .VERSION_MIN_WATCHOS,
            => break MachO.Options.Platform.fromLoadCommand(cmd),
            else => {},
        }
    } else null;
}

pub fn resolveSymbols(self: *Dylib, macho_file: *MachO) void {
    const slice = self.symtab.slice();
    for (self.symbols.items, 0..) |index, i| {
        const nlist_idx = @as(Symbol.Index, @intCast(i));
        const nlist = slice.items(.nlist)[nlist_idx];

        const global = macho_file.getSymbol(index);
        if (self.asFile().getSymbolRank(.{
            .weak = nlist.weakDef(),
        }) < global.getSymbolRank(macho_file)) {
            global.value = nlist.n_value;
            global.atom = 0;
            global.nlist_idx = nlist_idx;
            global.file = self.index;
            global.flags.weak = nlist.weakDef();
            global.flags.weak_ref = false;
            global.flags.tlv = slice.items(.tlv)[nlist_idx];
            global.flags.dyn_ref = false;
            global.flags.tentative = false;
            global.visibility = .global;
        }
    }
}

pub fn markLive(self: *Dylib, macho_file: *MachO) void {
    for (self.symbols.items) |index| {
        const global = macho_file.getSymbol(index);
        const file = global.getFile(macho_file) orelse continue;
        const should_drop = switch (file) {
            .dylib => |sh| !sh.needed and global.flags.weak_ref,
            else => false,
        };
        if (!should_drop and !file.isAlive()) {
            file.setAlive();
            file.markLive(macho_file);
        }
    }
}

pub fn resetGlobals(self: *Dylib, macho_file: *MachO) void {
    for (self.symbols.items) |sym_index| {
        const sym = macho_file.getSymbol(sym_index);
        const name = sym.name;
        sym.* = .{};
        sym.name = name;
    }
}

pub fn calcSymtabSize(self: *Dylib, macho_file: *MachO) !void {
    for (self.symbols.items) |global_index| {
        const global = macho_file.getSymbol(global_index);
        const file_ptr = global.getFile(macho_file) orelse continue;
        if (file_ptr.getIndex() != self.index) continue;
        if (global.isLocal()) continue;
        assert(global.flags.import);
        global.flags.output_symtab = true;
        try global.addExtra(.{ .symtab = self.output_symtab_ctx.nimports }, macho_file);
        self.output_symtab_ctx.nimports += 1;
        self.output_symtab_ctx.strsize += @as(u32, @intCast(global.getName(macho_file).len + 1));
    }
}

pub fn writeSymtab(self: Dylib, macho_file: *MachO) void {
    for (self.symbols.items) |global_index| {
        const global = macho_file.getSymbol(global_index);
        const file = global.getFile(macho_file) orelse continue;
        if (file.getIndex() != self.index) continue;
        const idx = global.getOutputSymtabIndex(macho_file) orelse continue;
        const n_strx = @as(u32, @intCast(macho_file.strtab.items.len));
        macho_file.strtab.appendSliceAssumeCapacity(global.getName(macho_file));
        macho_file.strtab.appendAssumeCapacity(0);
        const out_sym = &macho_file.symtab.items[idx];
        out_sym.n_strx = n_strx;
        global.setOutputSym(macho_file, out_sym);
    }
}

fn getLoadCommand(self: Dylib, lc: macho.LC) ?LoadCommandIterator.LoadCommand {
    var it = LoadCommandIterator{
        .ncmds = self.header.?.ncmds,
        .buffer = self.data[@sizeOf(macho.mach_header_64)..][0..self.header.?.sizeofcmds],
    };
    while (it.next()) |cmd| {
        if (cmd.cmd() == lc) return cmd;
    } else return null;
}

fn insertString(self: *Dylib, allocator: Allocator, name: []const u8) !u32 {
    const off = @as(u32, @intCast(self.strtab.items.len));
    try self.strtab.writer(allocator).print("{s}\x00", .{name});
    return off;
}

inline fn getString(self: Dylib, off: u32) [:0]const u8 {
    assert(off < self.strtab.items.len);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(self.strtab.items.ptr + off)), 0);
}

pub fn asFile(self: *Dylib) File {
    return .{ .dylib = self };
}

pub fn format(
    self: *Dylib,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = self;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format dylib directly");
}

pub fn fmtSymtab(self: *Dylib, macho_file: *MachO) std.fmt.Formatter(formatSymtab) {
    return .{ .data = .{
        .dylib = self,
        .macho_file = macho_file,
    } };
}

const FormatContext = struct {
    dylib: *Dylib,
    macho_file: *MachO,
};

fn formatSymtab(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const dylib = ctx.dylib;
    try writer.writeAll("  globals\n");
    for (dylib.symbols.items) |index| {
        const global = ctx.macho_file.getSymbol(index);
        try writer.print("    {}\n", .{global.fmt(ctx.macho_file)});
    }
}

pub const TargetMatcher = struct {
    allocator: Allocator,
    cpu_arch: std.Target.Cpu.Arch,
    platform: macho.PLATFORM,
    target_strings: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn init(allocator: Allocator, cpu_arch: std.Target.Cpu.Arch, platform: macho.PLATFORM) !TargetMatcher {
        var self = TargetMatcher{
            .allocator = allocator,
            .cpu_arch = cpu_arch,
            .platform = platform,
        };
        const apple_string = try targetToAppleString(allocator, cpu_arch, platform);
        try self.target_strings.append(allocator, apple_string);

        switch (platform) {
            .IOSSIMULATOR, .TVOSSIMULATOR, .WATCHOSSIMULATOR => {
                // For Apple simulator targets, linking gets tricky as we need to link against the simulator
                // hosts dylibs too.
                const host_target = try targetToAppleString(allocator, cpu_arch, .MACOS);
                try self.target_strings.append(allocator, host_target);
            },
            else => {},
        }

        return self;
    }

    pub fn deinit(self: *TargetMatcher) void {
        for (self.target_strings.items) |t| {
            self.allocator.free(t);
        }
        self.target_strings.deinit(self.allocator);
    }

    inline fn cpuArchToAppleString(cpu_arch: std.Target.Cpu.Arch) []const u8 {
        return switch (cpu_arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => unreachable,
        };
    }

    pub fn targetToAppleString(allocator: Allocator, cpu_arch: std.Target.Cpu.Arch, platform: macho.PLATFORM) ![]const u8 {
        const arch = cpuArchToAppleString(cpu_arch);
        const plat = switch (platform) {
            .MACOS => "macos",
            .IOS => "ios",
            .TVOS => "tvos",
            .WATCHOS => "watchos",
            .IOSSIMULATOR => "ios-simulator",
            .TVOSSIMULATOR => "tvos-simulator",
            .WATCHOSSIMULATOR => "watchos-simulator",
            .BRIDGEOS => "bridgeos",
            .MACCATALYST => "maccatalyst",
            .DRIVERKIT => "driverkit",
            else => unreachable,
        };
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, plat });
    }

    fn hasValue(stack: []const []const u8, needle: []const u8) bool {
        for (stack) |v| {
            if (mem.eql(u8, v, needle)) return true;
        }
        return false;
    }

    fn matchesArch(self: TargetMatcher, archs: []const []const u8) bool {
        return hasValue(archs, cpuArchToAppleString(self.cpu_arch));
    }

    fn matchesTarget(self: TargetMatcher, targets: []const []const u8) bool {
        for (self.target_strings.items) |t| {
            if (hasValue(targets, t)) return true;
        }
        return false;
    }

    pub fn matchesTargetTbd(self: TargetMatcher, tbd: Tbd) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const targets = switch (tbd) {
            .v3 => |v3| blk: {
                var targets = std.ArrayList([]const u8).init(arena.allocator());
                for (v3.archs) |arch| {
                    const target = try std.fmt.allocPrint(arena.allocator(), "{s}-{s}", .{ arch, v3.platform });
                    try targets.append(target);
                }
                break :blk targets.items;
            },
            .v4 => |v4| v4.targets,
        };

        return self.matchesTarget(targets);
    }
};

pub const Id = struct {
    name: []const u8,
    timestamp: u32,
    current_version: u32,
    compatibility_version: u32,

    pub fn default(allocator: Allocator, name: []const u8) !Id {
        return Id{
            .name = try allocator.dupe(u8, name),
            .timestamp = 2,
            .current_version = 0x10000,
            .compatibility_version = 0x10000,
        };
    }

    pub fn fromLoadCommand(allocator: Allocator, lc: macho.dylib_command, name: []const u8) !Id {
        return Id{
            .name = try allocator.dupe(u8, name),
            .timestamp = lc.dylib.timestamp,
            .current_version = lc.dylib.current_version,
            .compatibility_version = lc.dylib.compatibility_version,
        };
    }

    pub fn deinit(id: Id, allocator: Allocator) void {
        allocator.free(id.name);
    }

    pub const ParseError = fmt.ParseIntError || fmt.BufPrintError;

    pub fn parseCurrentVersion(id: *Id, version: anytype) ParseError!void {
        id.current_version = try parseVersion(version);
    }

    pub fn parseCompatibilityVersion(id: *Id, version: anytype) ParseError!void {
        id.compatibility_version = try parseVersion(version);
    }

    fn parseVersion(version: anytype) ParseError!u32 {
        const string = blk: {
            switch (version) {
                .int => |int| {
                    var out: u32 = 0;
                    const major = math.cast(u16, int) orelse return error.Overflow;
                    out += @as(u32, @intCast(major)) << 16;
                    return out;
                },
                .float => |float| {
                    var buf: [256]u8 = undefined;
                    break :blk try fmt.bufPrint(&buf, "{d:.2}", .{float});
                },
                .string => |string| {
                    break :blk string;
                },
            }
        };

        var out: u32 = 0;
        var values: [3][]const u8 = undefined;

        var split = mem.split(u8, string, ".");
        var count: u4 = 0;
        while (split.next()) |value| {
            if (count > 2) {
                log.debug("malformed version field: {s}", .{string});
                return 0x10000;
            }
            values[count] = value;
            count += 1;
        }

        if (count > 2) {
            out += try fmt.parseInt(u8, values[2], 10);
        }
        if (count > 1) {
            out += @as(u32, @intCast(try fmt.parseInt(u8, values[1], 10))) << 8;
        }
        out += @as(u32, @intCast(try fmt.parseInt(u16, values[0], 10))) << 16;

        return out;
    }
};

const Nlist = struct {
    nlist: macho.nlist_64,
    tlv: bool = false,
};

const assert = std.debug.assert;
const fat = @import("fat.zig");
const fs = std.fs;
const fmt = std.fmt;
const log = std.log.scoped(.link);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const tapi = @import("../tapi.zig");
const std = @import("std");

const Allocator = mem.Allocator;
const Dylib = @This();
const File = @import("file.zig").File;
const LibStub = tapi.LibStub;
const LoadCommandIterator = macho.LoadCommandIterator;
const MachO = @import("../MachO.zig");
const Symbol = @import("Symbol.zig");
const Tbd = tapi.Tbd;
