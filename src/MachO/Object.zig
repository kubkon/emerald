archive: ?[]const u8 = null,
path: []const u8,
mtime: u64,
data: []const u8,
index: File.Index,

header: ?macho.mach_header_64 = null,
sections: []align(1) const macho.section_64 = &[0]macho.section_64{},
symtab: std.ArrayListUnmanaged(macho.nlist_64) = .{},
strtab: []const u8 = &[0]u8{},
first_global: ?Symbol.Index = null,

symbols: std.ArrayListUnmanaged(Symbol.Index) = .{},
atoms: std.ArrayListUnmanaged(Atom.Index) = .{},

/// All relocations sorted and flatened, sorted by address descending
/// per section.
relocations: std.ArrayListUnmanaged(macho.relocation_info) = .{},

alive: bool = true,

pub fn deinit(self: *Object, gpa: Allocator) void {
    self.symtab.deinit(gpa);
    self.symbols.deinit(gpa);
    self.atoms.deinit(gpa);
    self.relocations.deinit(gpa);
}

pub fn parse(self: *Object, macho_file: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = macho_file.base.allocator;
    var stream = std.io.fixedBufferStream(self.data);
    const reader = stream.reader();

    self.header = try reader.readStruct(macho.mach_header_64);

    const lc_seg = self.getLoadCommand(.SEGMENT_64) orelse return;
    self.sections = lc_seg.getSections();

    const lc_symtab = self.getLoadCommand(.SYMTAB) orelse return;
    const cmd = lc_symtab.cast(macho.symtab_command).?;

    self.strtab = self.data[cmd.stroff..][0..cmd.strsize];

    const symtab = @as([*]align(1) const macho.nlist_64, @ptrCast(self.data.ptr + cmd.symoff))[0..cmd.nsyms];
    try self.symtab.ensureUnusedCapacity(gpa, symtab.len);
    self.symtab.appendUnalignedSliceAssumeCapacity(symtab);

    try self.initSectionAtoms(macho_file);
}

fn initSectionAtoms(self: *Object, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    try self.atoms.resize(gpa, self.sections.len);
    @memset(self.atoms.items, 0);

    for (self.sections, 0..) |sect, n_sect| {
        switch (sect.type()) {
            macho.S_REGULAR => {
                const attrs = sect.attrs();
                if (attrs & macho.S_ATTR_DEBUG != 0 and macho_file.options.strip) continue;
            },

            else => {},
        }

        const name = try std.fmt.allocPrintZ(gpa, "{s},{s}", .{ sect.segName(), sect.sectName() });
        defer gpa.free(name);
        const atom_index = try self.addAtom(name, sect.size, sect.@"align", @intCast(n_sect), macho_file);
        const atom = macho_file.getAtom(atom_index).?;
        atom.relocs = try self.parseRelocs(gpa, sect);
        atom.off = 0;
    }

    // const gpa = macho_file.base.allocator;
    // var symbols = std.ArrayList(macho.nlist_64).init(gpa);
    // defer symbols.deinit();

    // if (self.getLoadCommand(.DYSYMTAB)) |lc| {
    //     const cmd = lc.cast(macho.dysymtab_command).?;
    //     try symbols.appendSlice(self.symtab.items[0..cmd.iundefsym]);
    // } else {
    //     try symbols.ensureUnusedCapacity(self.symtab.items.len);
    //     for (self.symtab.items) |nlist| {
    //         if (nlist.sect()) symbols.appendAssumeCapacity(nlist);
    //     }
    // }

    // sortSymbols(symbols.items);

    // var sym_start: usize = 0;
    // for (self.sections, 1..) |sect, n_sect| {
    //     const sym_end = for (symbols.items[sym_start..], sym_start..) |sym, sym_i| {
    //         if (sym.n_sect != n_sect) break sym_i;
    //     } else symbols.items.len;

    //     if (sym_start == sym_end) break;

    //     // const relocs_loc = try self.parseRelocs(gpa, sect);
    //     // const relocs_end = relocs_loc.pos + relocs_loc.len;

    //     assert(symbols.items[sym_start].n_value == sect.addr);

    //     var sym_next: usize = sym_start;
    //     // var relocs_next: usize = relocs_loc.pos;
    //     while (sym_next < sym_end) {
    //         const first_nlist = symbols.items[sym_next];

    //         while (sym_next < sym_end and
    //             symbols.items[sym_next].n_value == first_nlist.n_value) : (sym_next += 1)
    //         {}

    //         const size = if (sym_next < sym_end)
    //             symbols.items[sym_next].n_value - first_nlist.n_value
    //         else
    //             sect.size;

    //         const alignment = if (first_nlist.n_value > 0)
    //             @min(@ctz(first_nlist.n_value), sect.@"align")
    //         else
    //             sect.@"align";

    //         _ = try self.addAtom(
    //             self.getString(first_nlist.n_strx),
    //             size,
    //             @intCast(alignment),
    //             @intCast(n_sect - 1),
    //             macho_file,
    //         );
    //     }

    //     sym_start = sym_end;
    // }
}

fn addAtom(
    self: *Object,
    name: [:0]const u8,
    size: u64,
    alignment: u32,
    n_sect: u8,
    macho_file: *MachO,
) !Atom.Index {
    const gpa = macho_file.base.allocator;
    const atom_index = try macho_file.addAtom();
    const atom = macho_file.getAtom(atom_index).?;
    atom.atom_index = atom_index;
    atom.name = try macho_file.string_intern.insert(gpa, name);
    atom.n_sect = n_sect;
    atom.size = size;
    atom.alignment = alignment;
    try self.atoms.append(gpa, atom_index);
    return atom_index;
}

fn sortSymbols(symbols: []macho.nlist_64) void {
    const nlistLessThan = struct {
        fn nlistLessThan(ctx: void, lhs: macho.nlist_64, rhs: macho.nlist_64) bool {
            _ = ctx;
            assert(lhs.sect() and rhs.sect());
            if (lhs.n_sect == rhs.n_sect) {
                if (lhs.n_value == rhs.n_value) {
                    return lhs.n_strx < rhs.n_strx;
                } else return lhs.n_value < rhs.n_value;
            } else return lhs.n_sect < rhs.n_sect;
        }
    }.nlistLessThan;
    mem.sort(macho.nlist_64, symbols, {}, nlistLessThan);
}

/// Parse all relocs for the input section, and sort in ascending order.
/// Previously, I have wrongly assumed the compilers output relocations for each
/// section in a sorted manner which is simply not true.
fn parseRelocs(self: *Object, allocator: Allocator, sect: macho.section_64) !Atom.Loc {
    const relocLessThan = struct {
        fn relocLessThan(ctx: void, lhs: macho.relocation_info, rhs: macho.relocation_info) bool {
            _ = ctx;
            return lhs.r_address < rhs.r_address;
        }
    }.relocLessThan;

    if (sect.nreloc == 0) return .{};
    const pos: u32 = @intCast(self.relocations.items.len);
    const relocs = @as(
        [*]align(1) const macho.relocation_info,
        @ptrCast(self.data.ptr + sect.reloff),
    )[0..sect.nreloc];
    try self.relocations.ensureUnusedCapacity(allocator, relocs.len);
    self.relocations.appendUnalignedSliceAssumeCapacity(relocs);
    mem.sort(macho.relocation_info, self.relocations.items[pos..], {}, relocLessThan);
    return .{ .pos = pos, .len = sect.nreloc };
}

fn getLoadCommand(self: Object, lc: macho.LC) ?LoadCommandIterator.LoadCommand {
    var it = LoadCommandIterator{
        .ncmds = self.header.?.ncmds,
        .buffer = self.data[@sizeOf(macho.mach_header_64)..][0..self.header.?.sizeofcmds],
    };
    while (it.next()) |cmd| {
        if (cmd.cmd() == lc) return cmd;
    } else return null;
}

fn getString(self: Object, off: u32) [:0]const u8 {
    assert(off < self.strtab.len);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(self.strtab.ptr + off)), 0);
}

pub fn format(
    self: *Object,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = self;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format objects directly");
}

const FormatContext = struct {
    object: *Object,
    macho_file: *MachO,
};

pub fn fmtAtoms(self: *Object, macho_file: *MachO) std.fmt.Formatter(formatAtoms) {
    return .{ .data = .{
        .object = self,
        .macho_file = macho_file,
    } };
}

fn formatAtoms(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    try writer.writeAll("  atoms\n");
    for (object.atoms.items) |atom_index| {
        const atom = ctx.macho_file.getAtom(atom_index) orelse continue;
        try writer.print("    {}\n", .{atom.fmt(ctx.macho_file)});
    }
}

pub fn fmtPath(self: *Object) std.fmt.Formatter(formatPath) {
    return .{ .data = self };
}

fn formatPath(
    object: *Object,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    if (object.archive) |path| {
        try writer.writeAll(path);
        try writer.writeByte('(');
        try writer.writeAll(object.path);
        try writer.writeByte(')');
    } else try writer.writeAll(object.path);
}

const assert = std.debug.assert;
const log = std.log.scoped(.link);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const trace = @import("../tracy.zig").trace;
const std = @import("std");

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const File = @import("file.zig").File;
const LoadCommandIterator = macho.LoadCommandIterator;
const MachO = @import("../MachO.zig");
const Object = @This();
const StringTable = @import("../strtab.zig").StringTable;
const Symbol = @import("Symbol.zig");
