pub const Cie = struct {
    /// Includes 4byte size cell.
    offset: u32,
    size: u32,
    lsda_size: ?enum { p32, p64 } = null,
    personality: ?Personality = null,
    file: File.Index = 0,
    alive: bool = true,

    pub fn parse(cie: *Cie, macho_file: *MachO) !void {
        const data = cie.getData(macho_file);
        const aug = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(data.ptr + 9)), 0);

        if (aug[0] != 'z') return; // TODO should we error out?

        var stream = std.io.fixedBufferStream(data[9 + aug.len + 1 ..]);
        var creader = std.io.countingReader(stream.reader());
        const reader = creader.reader();

        _ = try leb.readULEB128(u64, reader); // code alignment factor
        _ = try leb.readULEB128(u64, reader); // data alignment factor
        _ = try leb.readULEB128(u64, reader); // return address register
        _ = try leb.readULEB128(u64, reader); // augmentation data length

        for (aug[1..]) |ch| switch (ch) {
            'R' => {
                const enc = try reader.readByte();
                if (enc & 0xf != EH_PE.absptr or enc & EH_PE.pcrel == 0) {
                    @panic("unexpected pointer encoding"); // TODO error
                }
            },
            'P' => {
                const enc = try reader.readByte();
                if (enc != EH_PE.pcrel | EH_PE.indirect | EH_PE.sdata4) {
                    @panic("unexpected personality pointer encoding"); // TODO error
                }
                _ = try reader.readInt(u32, .little); // personality pointer
            },
            'L' => {
                const enc = try reader.readByte();
                switch (enc & 0xf) {
                    EH_PE.sdata4 => cie.lsda_size = .p32,
                    EH_PE.absptr => cie.lsda_size = .p64,
                    else => unreachable, // TODO error
                }
            },
            else => @panic("unexpected augmentation string"), // TODO error
        };
    }

    pub inline fn getSize(cie: Cie) u32 {
        return cie.size + 4;
    }

    pub fn getObject(cie: Cie, macho_file: *MachO) *Object {
        const file = macho_file.getFile(cie.file).?;
        return file.object;
    }

    pub fn getData(cie: Cie, macho_file: *MachO) []const u8 {
        const object = cie.getObject(macho_file);
        const data = object.getSectionData(object.eh_frame_sect_index.?);
        return data[cie.offset..][0..cie.getSize()];
    }

    pub fn getPersonalityTarget(cie: Cie, macho_file: *MachO) ?*Symbol {
        const personality = cie.personality orelse return null;
        return macho_file.getSymbol(personality.index);
    }

    pub fn getPersonalityOffset(cie: Cie) ?u32 {
        const personality = cie.personality orelse return null;
        return personality.offset;
    }

    pub const Index = u32;

    pub const Personality = struct {
        index: Symbol.Index = 0,
        offset: u32 = 0,
    };
};

pub const Fde = struct {
    /// Includes 4byte size cell.
    offset: u32,
    size: u32,
    cie: Cie.Index,
    atom: Atom.Index = 0,
    lsda: Atom.Index = 0,
    file: File.Index = 0,
    alive: bool = true,

    pub fn parse(fde: *Fde, macho_file: *MachO) !void {
        const data = fde.getData(macho_file);
        const object = fde.getObject(macho_file);
        const sect = object.sections.items(.header)[object.eh_frame_sect_index.?];

        // Parse target atom index
        const pc_begin = std.mem.readInt(i64, data[8..][0..8], .little);
        const taddr: u64 = @intCast(@as(i64, @intCast(sect.addr + fde.offset + 8)) + pc_begin);
        fde.atom = object.findAtom(taddr);
        assert(fde.atom != 0); // TODO convert into an error

        // Associate with a CIE
        const cie_ptr = std.mem.readInt(u32, data[4..8], .little);
        const cie_offset = fde.offset + 4 - cie_ptr;
        const cie_index = for (object.cies.items, 0..) |cie, cie_index| {
            if (cie.offset == cie_offset) break @as(Cie.Index, @intCast(cie_index));
        } else null;
        if (cie_index) |cie| {
            fde.cie = cie;
        } else {
            macho_file.base.fatal("{}: no matching CIE found for FDE at offset {x}", .{
                object.fmtPath(),
                fde.offset,
            });
            return;
        }

        const cie = fde.getCie(macho_file);

        // Parse LSDA atom index if any
        if (cie.lsda_size) |lsda_size| {
            var stream = std.io.fixedBufferStream(data[24..]);
            var creader = std.io.countingReader(stream.reader());
            const reader = creader.reader();
            _ = try leb.readULEB128(u64, reader); // augmentation length
            const offset = creader.bytes_read;
            const lsda_ptr = switch (lsda_size) {
                .p32 => try reader.readInt(i32, .little),
                .p64 => try reader.readInt(i64, .little),
            };
            const lsda_addr: u64 = @intCast(@as(i64, @intCast(sect.addr + 24 + offset + fde.offset)) + lsda_ptr);
            fde.lsda = object.findAtom(lsda_addr);
            assert(fde.getLsdaAtom(macho_file) != null); // TODO convert into an error
        }
    }

    pub inline fn getSize(fde: Fde) u32 {
        return fde.size + 4;
    }

    pub fn getObject(fde: Fde, macho_file: *MachO) *Object {
        const file = macho_file.getFile(fde.file).?;
        return file.object;
    }

    pub fn getData(fde: Fde, macho_file: *MachO) []const u8 {
        const object = fde.getObject(macho_file);
        const data = object.getSectionData(object.eh_frame_sect_index.?);
        return data[fde.offset..][0..fde.getSize()];
    }

    pub fn getCie(fde: Fde, macho_file: *MachO) *const Cie {
        const object = fde.getObject(macho_file);
        return &object.cies.items[fde.cie];
    }

    pub fn getAtom(fde: Fde, macho_file: *MachO) *Atom {
        return macho_file.getAtom(fde.atom).?;
    }

    pub fn getLsdaAtom(fde: Fde, macho_file: *MachO) ?*Atom {
        return macho_file.getAtom(fde.lsda);
    }
};

// pub fn scanRelocs(macho_file: *MachO) !void {
//     const gpa = macho_file.base.allocator;

//     for (macho_file.objects.items, 0..) |*object, object_id| {
//         var cies = std.AutoHashMap(u32, void).init(gpa);
//         defer cies.deinit();

//         var it = object.getEhFrameRecordsIterator();

//         for (object.exec_atoms.items) |atom_index| {
//             var inner_syms_it = Atom.getInnerSymbolsIterator(macho_file, atom_index);
//             while (inner_syms_it.next()) |sym| {
//                 const fde_offset = object.eh_frame_records_lookup.get(sym) orelse continue;
//                 if (object.eh_frame_relocs_lookup.get(fde_offset).?.dead) continue;
//                 it.seekTo(fde_offset);
//                 const fde = (try it.next(macho_file)).?;

//                 const cie_ptr = fde.getCiePointerSource(@as(u32, @intCast(object_id)), macho_file, fde_offset);
//                 const cie_offset = fde_offset + 4 - cie_ptr;

//                 if (!cies.contains(cie_offset)) {
//                     try cies.putNoClobber(cie_offset, {});
//                     it.seekTo(cie_offset);
//                     const cie = (try it.next(macho_file)).?;
//                     try cie.scanRelocs(macho_file, @as(u32, @intCast(object_id)), cie_offset);
//                 }
//             }
//         }
//     }
// }

// pub fn calcSectionSize(macho_file: *MachO, unwind_info: *const UnwindInfo) !void {
//     const sect_id = macho_file.getSectionByName("__TEXT", "__eh_frame") orelse return;
//     const sect = &macho_file.sections.items(.header)[sect_id];
//     sect.@"align" = 3;
//     sect.size = 0;

//     const cpu_arch = macho_file.options.cpu_arch.?;
//     const gpa = macho_file.base.allocator;
//     var size: u32 = 0;

//     for (macho_file.objects.items, 0..) |*object, object_id| {
//         var cies = std.AutoHashMap(u32, u32).init(gpa);
//         defer cies.deinit();

//         var eh_it = object.getEhFrameRecordsIterator();

//         for (object.exec_atoms.items) |atom_index| {
//             var inner_syms_it = Atom.getInnerSymbolsIterator(macho_file, atom_index);
//             while (inner_syms_it.next()) |sym| {
//                 const fde_record_offset = object.eh_frame_records_lookup.get(sym) orelse continue;
//                 if (object.eh_frame_relocs_lookup.get(fde_record_offset).?.dead) continue;

//                 const record_id = unwind_info.records_lookup.get(sym) orelse continue;
//                 const record = unwind_info.records.items[record_id];

//                 // TODO skip this check if no __compact_unwind is present
//                 const is_dwarf = UnwindInfo.UnwindEncoding.isDwarf(record.compactUnwindEncoding, cpu_arch);
//                 if (!is_dwarf) continue;

//                 eh_it.seekTo(fde_record_offset);
//                 const source_fde_record = (try eh_it.next(macho_file)).?;

//                 const cie_ptr = source_fde_record.getCiePointerSource(@as(u32, @intCast(object_id)), macho_file, fde_record_offset);
//                 const cie_offset = fde_record_offset + 4 - cie_ptr;

//                 const gop = try cies.getOrPut(cie_offset);
//                 if (!gop.found_existing) {
//                     eh_it.seekTo(cie_offset);
//                     const source_cie_record = (try eh_it.next(macho_file)).?;
//                     gop.value_ptr.* = size;
//                     size += source_cie_record.getSize();
//                 }

//                 size += source_fde_record.getSize();
//             }
//         }
//     }

//     sect.size = size;
// }

// pub fn write(macho_file: *MachO, unwind_info: *UnwindInfo) !void {
//     const sect_id = macho_file.getSectionByName("__TEXT", "__eh_frame") orelse return;
//     const sect = macho_file.sections.items(.header)[sect_id];
//     const seg_id = macho_file.sections.items(.segment_index)[sect_id];
//     const seg = macho_file.segments.items[seg_id];

//     const cpu_arch = macho_file.options.cpu_arch.?;

//     const gpa = macho_file.base.allocator;
//     var eh_records = std.AutoArrayHashMap(u32, EhFrameRecord(true)).init(gpa);
//     defer {
//         for (eh_records.values()) |*rec| {
//             rec.deinit(gpa);
//         }
//         eh_records.deinit();
//     }

//     var eh_frame_offset: u32 = 0;

//     for (macho_file.objects.items, 0..) |*object, object_id| {
//         try eh_records.ensureUnusedCapacity(2 * @as(u32, @intCast(object.exec_atoms.items.len)));

//         var cies = std.AutoHashMap(u32, u32).init(gpa);
//         defer cies.deinit();

//         var eh_it = object.getEhFrameRecordsIterator();

//         for (object.exec_atoms.items) |atom_index| {
//             var inner_syms_it = Atom.getInnerSymbolsIterator(macho_file, atom_index);
//             while (inner_syms_it.next()) |target| {
//                 const fde_record_offset = object.eh_frame_records_lookup.get(target) orelse continue;
//                 if (object.eh_frame_relocs_lookup.get(fde_record_offset).?.dead) continue;

//                 const record_id = unwind_info.records_lookup.get(target) orelse continue;
//                 const record = &unwind_info.records.items[record_id];

//                 // TODO skip this check if no __compact_unwind is present
//                 const is_dwarf = UnwindInfo.UnwindEncoding.isDwarf(record.compactUnwindEncoding, cpu_arch);
//                 if (!is_dwarf) continue;

//                 eh_it.seekTo(fde_record_offset);
//                 const source_fde_record = (try eh_it.next(macho_file)).?;

//                 const cie_ptr = source_fde_record.getCiePointerSource(@as(u32, @intCast(object_id)), macho_file, fde_record_offset);
//                 const cie_offset = fde_record_offset + 4 - cie_ptr;

//                 const gop = try cies.getOrPut(cie_offset);
//                 if (!gop.found_existing) {
//                     eh_it.seekTo(cie_offset);
//                     const source_cie_record = (try eh_it.next(macho_file)).?;
//                     var cie_record = try source_cie_record.toOwned(gpa);
//                     try cie_record.relocate(macho_file, @as(u32, @intCast(object_id)), .{
//                         .source_offset = cie_offset,
//                         .out_offset = eh_frame_offset,
//                         .sect_addr = sect.addr,
//                     });
//                     eh_records.putAssumeCapacityNoClobber(eh_frame_offset, cie_record);
//                     gop.value_ptr.* = eh_frame_offset;
//                     eh_frame_offset += cie_record.getSize();
//                 }

//                 var fde_record = try source_fde_record.toOwned(gpa);
//                 try fde_record.relocate(macho_file, @as(u32, @intCast(object_id)), .{
//                     .source_offset = fde_record_offset,
//                     .out_offset = eh_frame_offset,
//                     .sect_addr = sect.addr,
//                 });
//                 fde_record.setCiePointer(eh_frame_offset + 4 - gop.value_ptr.*);

//                 switch (cpu_arch) {
//                     .aarch64 => {}, // relocs take care of LSDA pointers
//                     .x86_64 => {
//                         // We need to relocate target symbol address ourselves.
//                         const atom_sym = macho_file.getSymbol(target);
//                         try fde_record.setTargetSymbolAddress(atom_sym.n_value, .{
//                             .base_addr = sect.addr,
//                             .base_offset = eh_frame_offset,
//                         });

//                         // We need to parse LSDA pointer and relocate ourselves.
//                         const cie_record = eh_records.get(
//                             eh_frame_offset + 4 - fde_record.getCiePointer(),
//                         ).?;
//                         const eh_frame_sect = object.getSourceSection(object.eh_frame_sect_id.?);
//                         const source_lsda_ptr = try fde_record.getLsdaPointer(cie_record, .{
//                             .base_addr = eh_frame_sect.addr,
//                             .base_offset = fde_record_offset,
//                         });
//                         if (source_lsda_ptr) |ptr| {
//                             const sym_index = object.getSymbolByAddress(ptr, null);
//                             const sym = object.symtab[sym_index];
//                             try fde_record.setLsdaPointer(cie_record, sym.n_value, .{
//                                 .base_addr = sect.addr,
//                                 .base_offset = eh_frame_offset,
//                             });
//                         }
//                     },
//                     else => unreachable,
//                 }

//                 eh_records.putAssumeCapacityNoClobber(eh_frame_offset, fde_record);

//                 UnwindInfo.UnwindEncoding.setDwarfSectionOffset(
//                     &record.compactUnwindEncoding,
//                     cpu_arch,
//                     @as(u24, @intCast(eh_frame_offset)),
//                 );

//                 const cie_record = eh_records.get(
//                     eh_frame_offset + 4 - fde_record.getCiePointer(),
//                 ).?;
//                 const lsda_ptr = try fde_record.getLsdaPointer(cie_record, .{
//                     .base_addr = sect.addr,
//                     .base_offset = eh_frame_offset,
//                 });
//                 if (lsda_ptr) |ptr| {
//                     record.lsda = ptr - seg.vmaddr;
//                 }

//                 eh_frame_offset += fde_record.getSize();
//             }
//         }
//     }

//     var buffer = std.ArrayList(u8).init(gpa);
//     defer buffer.deinit();
//     const writer = buffer.writer();

//     for (eh_records.values()) |record| {
//         try writer.writeInt(u32, record.size, .little);
//         try buffer.appendSlice(record.data);
//     }

//     try macho_file.base.file.pwriteAll(buffer.items, sect.offset);
// }
// const EhFrameRecordTag = enum { cie, fde };

// pub fn EhFrameRecord(comptime is_mutable: bool) type {
//     return struct {
//         tag: EhFrameRecordTag,
//         size: u32,
//         data: if (is_mutable) []u8 else []const u8,

//         const Record = @This();

//         pub fn deinit(rec: *Record, gpa: Allocator) void {
//             comptime assert(is_mutable);
//             gpa.free(rec.data);
//         }

//         pub fn toOwned(rec: Record, gpa: Allocator) Allocator.Error!EhFrameRecord(true) {
//             const data = try gpa.dupe(u8, rec.data);
//             return EhFrameRecord(true){
//                 .tag = rec.tag,
//                 .size = rec.size,
//                 .data = data,
//             };
//         }

//         pub inline fn getSize(rec: Record) u32 {
//             return 4 + rec.size;
//         }

//         pub fn scanRelocs(
//             rec: Record,
//             macho_file: *MachO,
//             object_id: u32,
//             source_offset: u32,
//         ) !void {
//             if (rec.getPersonalityPointerReloc(macho_file, object_id, source_offset)) |target| {
//                 try Atom.addGotEntry(macho_file, target);
//             }
//         }

//         pub fn getTargetSymbolAddress(rec: Record, ctx: struct {
//             base_addr: u64,
//             base_offset: u64,
//         }) u64 {
//             assert(rec.tag == .fde);
//             const addend = mem.readInt(i64, rec.data[4..][0..8], .little);
//             return @as(u64, @intCast(@as(i64, @intCast(ctx.base_addr + ctx.base_offset + 8)) + addend));
//         }

//         pub fn setTargetSymbolAddress(rec: *Record, value: u64, ctx: struct {
//             base_addr: u64,
//             base_offset: u64,
//         }) !void {
//             assert(rec.tag == .fde);
//             const addend = @as(i64, @intCast(value)) - @as(i64, @intCast(ctx.base_addr + ctx.base_offset + 8));
//             mem.writeInt(i64, rec.data[4..][0..8], addend, .little);
//         }

//         pub fn getPersonalityPointerReloc(
//             rec: Record,
//             macho_file: *MachO,
//             object_id: u32,
//             source_offset: u32,
//         ) ?MachO.SymbolWithLoc {
//             const cpu_arch = macho_file.options.cpu_arch.?;
//             const relocs = getRelocs(macho_file, object_id, source_offset);
//             for (relocs) |rel| {
//                 switch (cpu_arch) {
//                     .aarch64 => {
//                         const rel_type = @as(macho.reloc_type_arm64, @enumFromInt(rel.r_type));
//                         switch (rel_type) {
//                             .ARM64_RELOC_SUBTRACTOR,
//                             .ARM64_RELOC_UNSIGNED,
//                             => continue,
//                             .ARM64_RELOC_POINTER_TO_GOT => {},
//                             else => unreachable,
//                         }
//                     },
//                     .x86_64 => {
//                         const rel_type = @as(macho.reloc_type_x86_64, @enumFromInt(rel.r_type));
//                         switch (rel_type) {
//                             .X86_64_RELOC_GOT => {},
//                             else => unreachable,
//                         }
//                     },
//                     else => unreachable,
//                 }
//                 const target = Atom.parseRelocTarget(macho_file, .{
//                     .object_id = object_id,
//                     .rel = rel,
//                     .code = rec.data,
//                     .base_offset = @as(i32, @intCast(source_offset)) + 4,
//                 });
//                 return target;
//             }
//             return null;
//         }

//         pub fn relocate(rec: *Record, macho_file: *MachO, object_id: u32, ctx: struct {
//             source_offset: u32,
//             out_offset: u32,
//             sect_addr: u64,
//         }) !void {
//             comptime assert(is_mutable);

//             const cpu_arch = macho_file.options.cpu_arch.?;
//             const relocs = getRelocs(macho_file, object_id, ctx.source_offset);

//             for (relocs) |rel| {
//                 const target = Atom.parseRelocTarget(macho_file, .{
//                     .object_id = object_id,
//                     .rel = rel,
//                     .code = rec.data,
//                     .base_offset = @as(i32, @intCast(ctx.source_offset)) + 4,
//                 });
//                 const rel_offset = @as(u32, @intCast(rel.r_address - @as(i32, @intCast(ctx.source_offset)) - 4));
//                 const source_addr = ctx.sect_addr + rel_offset + ctx.out_offset + 4;

//                 switch (cpu_arch) {
//                     .aarch64 => {
//                         const rel_type = @as(macho.reloc_type_arm64, @enumFromInt(rel.r_type));
//                         switch (rel_type) {
//                             .ARM64_RELOC_SUBTRACTOR => {
//                                 // Address of the __eh_frame in the source object file
//                             },
//                             .ARM64_RELOC_POINTER_TO_GOT => {
//                                 const target_addr = try Atom.getRelocTargetAddress(macho_file, target, true, false);
//                                 const result = math.cast(i32, @as(i64, @intCast(target_addr)) - @as(i64, @intCast(source_addr))) orelse
//                                     return error.Overflow;
//                                 mem.writeInt(i32, rec.data[rel_offset..][0..4], result, .little);
//                             },
//                             .ARM64_RELOC_UNSIGNED => {
//                                 assert(rel.r_extern == 1);
//                                 const target_addr = try Atom.getRelocTargetAddress(macho_file, target, false, false);
//                                 const result = @as(i64, @intCast(target_addr)) - @as(i64, @intCast(source_addr));
//                                 mem.writeInt(i64, rec.data[rel_offset..][0..8], @as(i64, @intCast(result)), .little);
//                             },
//                             else => unreachable,
//                         }
//                     },
//                     .x86_64 => {
//                         const rel_type = @as(macho.reloc_type_x86_64, @enumFromInt(rel.r_type));
//                         switch (rel_type) {
//                             .X86_64_RELOC_GOT => {
//                                 const target_addr = try Atom.getRelocTargetAddress(macho_file, target, true, false);
//                                 const addend = mem.readInt(i32, rec.data[rel_offset..][0..4], .little);
//                                 const adjusted_target_addr = @as(u64, @intCast(@as(i64, @intCast(target_addr)) + addend));
//                                 const disp = try Atom.calcPcRelativeDisplacementX86(source_addr, adjusted_target_addr, 0);
//                                 mem.writeInt(i32, rec.data[rel_offset..][0..4], disp, .little);
//                             },
//                             else => unreachable,
//                         }
//                     },
//                     else => unreachable,
//                 }
//             }
//         }

//         pub fn getCiePointerSource(rec: Record, object_id: u32, macho_file: *MachO, offset: u32) u32 {
//             assert(rec.tag == .fde);
//             const cpu_arch = macho_file.options.cpu_arch.?;
//             const addend = mem.readInt(u32, rec.data[0..4], .little);
//             switch (cpu_arch) {
//                 .aarch64 => {
//                     const relocs = getRelocs(macho_file, object_id, offset);
//                     const maybe_rel = for (relocs) |rel| {
//                         if (rel.r_address - @as(i32, @intCast(offset)) == 4 and
//                             @as(macho.reloc_type_arm64, @enumFromInt(rel.r_type)) == .ARM64_RELOC_SUBTRACTOR)
//                             break rel;
//                     } else null;
//                     const rel = maybe_rel orelse return addend;
//                     const object = &macho_file.objects.items[object_id];
//                     const target_addr = object.in_symtab.?[rel.r_symbolnum].n_value;
//                     const sect = object.getSourceSection(object.eh_frame_sect_id.?);
//                     return @as(u32, @intCast(sect.addr + offset - target_addr + addend));
//                 },
//                 .x86_64 => return addend,
//                 else => unreachable,
//             }
//         }

//         pub fn getCiePointer(rec: Record) u32 {
//             assert(rec.tag == .fde);
//             return mem.readInt(u32, rec.data[0..4], .little);
//         }

//         pub fn setCiePointer(rec: *Record, ptr: u32) void {
//             assert(rec.tag == .fde);
//             mem.writeInt(u32, rec.data[0..4], ptr, .little);
//         }

//         pub fn getAugmentationString(rec: Record) []const u8 {
//             assert(rec.tag == .cie);
//             return mem.sliceTo(@as([*:0]const u8, @ptrCast(rec.data.ptr + 5)), 0);
//         }

//         pub fn getPersonalityPointer(rec: Record, ctx: struct {
//             base_addr: u64,
//             base_offset: u64,
//         }) !?u64 {
//             assert(rec.tag == .cie);
//             const aug_str = rec.getAugmentationString();

//             var stream = std.io.fixedBufferStream(rec.data[9 + aug_str.len ..]);
//             var creader = std.io.countingReader(stream.reader());
//             const reader = creader.reader();

//             for (aug_str, 0..) |ch, i| switch (ch) {
//                 'z' => if (i > 0) {
//                     return error.MalformedAugmentationString;
//                 } else {
//                     _ = try leb.readULEB128(u64, reader);
//                 },
//                 'R' => {
//                     _ = try reader.readByte();
//                 },
//                 'P' => {
//                     const enc = try reader.readByte();
//                     const offset = ctx.base_offset + 13 + aug_str.len + creader.bytes_read;
//                     const ptr = try getEncodedPointer(enc, @as(i64, @intCast(ctx.base_addr + offset)), reader);
//                     return ptr;
//                 },
//                 'L' => {
//                     _ = try reader.readByte();
//                 },
//                 'S', 'B', 'G' => {},
//                 else => return error.UnknownAugmentationStringValue,
//             };

//             return null;
//         }

//         pub fn getLsdaPointer(rec: Record, cie: Record, ctx: struct {
//             base_addr: u64,
//             base_offset: u64,
//         }) !?u64 {
//             assert(rec.tag == .fde);
//             const enc = (try cie.getLsdaEncoding()) orelse return null;
//             var stream = std.io.fixedBufferStream(rec.data[20..]);
//             const reader = stream.reader();
//             _ = try reader.readByte();
//             const offset = ctx.base_offset + 25;
//             const ptr = try getEncodedPointer(enc, @as(i64, @intCast(ctx.base_addr + offset)), reader);
//             return ptr;
//         }

//         pub fn setLsdaPointer(rec: *Record, cie: Record, value: u64, ctx: struct {
//             base_addr: u64,
//             base_offset: u64,
//         }) !void {
//             assert(rec.tag == .fde);
//             const enc = (try cie.getLsdaEncoding()) orelse unreachable;
//             var stream = std.io.fixedBufferStream(rec.data[21..]);
//             const writer = stream.writer();
//             const offset = ctx.base_offset + 25;
//             try setEncodedPointer(enc, @as(i64, @intCast(ctx.base_addr + offset)), value, writer);
//         }

//         fn getLsdaEncoding(rec: Record) !?u8 {
//             assert(rec.tag == .cie);
//             const aug_str = rec.getAugmentationString();

//             const base_offset = 9 + aug_str.len;
//             var stream = std.io.fixedBufferStream(rec.data[base_offset..]);
//             var creader = std.io.countingReader(stream.reader());
//             const reader = creader.reader();

//             for (aug_str, 0..) |ch, i| switch (ch) {
//                 'z' => if (i > 0) {
//                     return error.MalformedAugmentationString;
//                 } else {
//                     _ = try leb.readULEB128(u64, reader);
//                 },
//                 'R' => {
//                     _ = try reader.readByte();
//                 },
//                 'P' => {
//                     const enc = try reader.readByte();
//                     _ = try getEncodedPointer(enc, 0, reader);
//                 },
//                 'L' => {
//                     const enc = try reader.readByte();
//                     return enc;
//                 },
//                 'S', 'B', 'G' => {},
//                 else => return error.UnknownAugmentationStringValue,
//             };

//             return null;
//         }

//         fn getEncodedPointer(enc: u8, pcrel_offset: i64, reader: anytype) !?u64 {
//             if (enc == EH_PE.omit) return null;

//             var ptr: i64 = switch (enc & 0x0F) {
//                 EH_PE.absptr => @as(i64, @bitCast(try reader.readInt(u64, .little))),
//                 EH_PE.udata2 => @as(i16, @bitCast(try reader.readInt(u16, .little))),
//                 EH_PE.udata4 => @as(i32, @bitCast(try reader.readInt(u32, .little))),
//                 EH_PE.udata8 => @as(i64, @bitCast(try reader.readInt(u64, .little))),
//                 EH_PE.uleb128 => @as(i64, @bitCast(try leb.readULEB128(u64, reader))),
//                 EH_PE.sdata2 => try reader.readInt(i16, .little),
//                 EH_PE.sdata4 => try reader.readInt(i32, .little),
//                 EH_PE.sdata8 => try reader.readInt(i64, .little),
//                 EH_PE.sleb128 => try leb.readILEB128(i64, reader),
//                 else => return null,
//             };

//             switch (enc & 0x70) {
//                 EH_PE.absptr => {},
//                 EH_PE.pcrel => ptr += pcrel_offset,
//                 EH_PE.datarel,
//                 EH_PE.textrel,
//                 EH_PE.funcrel,
//                 EH_PE.aligned,
//                 => return null,
//                 else => return null,
//             }

//             return @as(u64, @bitCast(ptr));
//         }

//         fn setEncodedPointer(enc: u8, pcrel_offset: i64, value: u64, writer: anytype) !void {
//             if (enc == EH_PE.omit) return;

//             var actual = @as(i64, @intCast(value));

//             switch (enc & 0x70) {
//                 EH_PE.absptr => {},
//                 EH_PE.pcrel => actual -= pcrel_offset,
//                 EH_PE.datarel,
//                 EH_PE.textrel,
//                 EH_PE.funcrel,
//                 EH_PE.aligned,
//                 => unreachable,
//                 else => unreachable,
//             }

//             switch (enc & 0x0F) {
//                 EH_PE.absptr => try writer.writeInt(u64, @as(u64, @bitCast(actual)), .little),
//                 EH_PE.udata2 => try writer.writeInt(u16, @as(u16, @bitCast(@as(i16, @intCast(actual)))), .little),
//                 EH_PE.udata4 => try writer.writeInt(u32, @as(u32, @bitCast(@as(i32, @intCast(actual)))), .little),
//                 EH_PE.udata8 => try writer.writeInt(u64, @as(u64, @bitCast(actual)), .little),
//                 EH_PE.uleb128 => try leb.writeULEB128(writer, @as(u64, @bitCast(actual))),
//                 EH_PE.sdata2 => try writer.writeInt(i16, @as(i16, @intCast(actual)), .little),
//                 EH_PE.sdata4 => try writer.writeInt(i32, @as(i32, @intCast(actual)), .little),
//                 EH_PE.sdata8 => try writer.writeInt(i64, actual, .little),
//                 EH_PE.sleb128 => try leb.writeILEB128(writer, actual),
//                 else => unreachable,
//             }
//         }
//     };
// }

// pub fn getRelocs(macho_file: *MachO, object_id: u32, source_offset: u32) []const macho.relocation_info {
//     const object = &macho_file.objects.items[object_id];
//     assert(object.hasEhFrameRecords());
//     const urel = object.eh_frame_relocs_lookup.get(source_offset) orelse
//         return &[0]macho.relocation_info{};
//     const all_relocs = object.getRelocs(object.eh_frame_sect_id.?);
//     return all_relocs[urel.reloc.start..][0..urel.reloc.len];
// }

pub const Iterator = struct {
    data: []const u8,
    pos: u32 = 0,

    pub const Record = struct {
        tag: enum { fde, cie },
        offset: u32,
        size: u32,
    };

    pub fn next(it: *Iterator) !?Record {
        if (it.pos >= it.data.len) return null;

        var stream = std.io.fixedBufferStream(it.data[it.pos..]);
        const reader = stream.reader();

        const size = try reader.readInt(u32, .little);
        if (size == 0xFFFFFFFF) @panic("DWARF CFI is 32bit on macOS");

        const id = try reader.readInt(u32, .little);
        const record = Record{
            .tag = if (id == 0) .cie else .fde,
            .offset = it.pos,
            .size = size,
        };
        it.pos += size + 4;

        return record;
    }
};

pub const EH_PE = struct {
    pub const absptr = 0x00;
    pub const uleb128 = 0x01;
    pub const udata2 = 0x02;
    pub const udata4 = 0x03;
    pub const udata8 = 0x04;
    pub const sleb128 = 0x09;
    pub const sdata2 = 0x0A;
    pub const sdata4 = 0x0B;
    pub const sdata8 = 0x0C;
    pub const pcrel = 0x10;
    pub const textrel = 0x20;
    pub const datarel = 0x30;
    pub const funcrel = 0x40;
    pub const aligned = 0x50;
    pub const indirect = 0x80;
    pub const omit = 0xFF;
};

const std = @import("std");
const assert = std.debug.assert;
const leb = std.leb;
const macho = std.macho;

const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const File = @import("file.zig").File;
const MachO = @import("../MachO.zig");
const Object = @import("Object.zig");
const Symbol = @import("Symbol.zig");
