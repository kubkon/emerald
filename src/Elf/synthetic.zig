pub const DynamicSection = struct {
    soname: ?u32 = null,
    needed: std.ArrayListUnmanaged(u32) = .{},
    rpath: u32 = 0,

    pub fn deinit(dt: *DynamicSection, allocator: Allocator) void {
        dt.needed.deinit(allocator);
    }

    pub fn addNeeded(dt: *DynamicSection, shared: *SharedObject, elf_file: *Elf) !void {
        const gpa = elf_file.base.allocator;
        const off = try elf_file.insertDynString(shared.getSoname());
        try dt.needed.append(gpa, off);
    }

    pub fn setRpath(dt: *DynamicSection, rpath_list: []const []const u8, elf_file: *Elf) !void {
        if (rpath_list.len == 0) return;
        const gpa = elf_file.base.allocator;
        var rpath = std.ArrayList(u8).init(gpa);
        defer rpath.deinit();
        for (rpath_list, 0..) |path, i| {
            if (i > 0) try rpath.append(':');
            try rpath.appendSlice(path);
        }
        dt.rpath = try elf_file.insertDynString(rpath.items);
    }

    pub fn setSoname(dt: *DynamicSection, soname: []const u8, elf_file: *Elf) !void {
        dt.soname = try elf_file.insertDynString(soname);
    }

    fn getFlags(dt: DynamicSection, elf_file: *Elf) ?u64 {
        _ = dt;
        var flags: u64 = 0;
        if (elf_file.options.z_now) {
            flags |= elf.DF_BIND_NOW;
        }
        for (elf_file.got.entries.items) |entry| switch (entry.tag) {
            .gottp => {
                flags |= elf.DF_STATIC_TLS;
                break;
            },
            else => {},
        };
        if (elf_file.has_text_reloc) {
            flags |= elf.DF_TEXTREL;
        }
        return if (flags > 0) flags else null;
    }

    fn getFlags1(dt: DynamicSection, elf_file: *Elf) ?u64 {
        _ = dt;
        var flags_1: u64 = 0;
        if (elf_file.options.z_now) {
            flags_1 |= elf.DF_1_NOW;
        }
        if (elf_file.options.pie) {
            flags_1 |= elf.DF_1_PIE;
        }
        if (elf_file.options.z_nodlopen) {
            flags_1 |= elf.DF_1_NOOPEN;
        }
        return if (flags_1 > 0) flags_1 else null;
    }

    pub fn size(dt: DynamicSection, elf_file: *Elf) usize {
        const is_shared = elf_file.options.shared;
        var nentries: usize = 0;
        nentries += dt.needed.items.len; // NEEDED
        if (dt.soname != null) nentries += 1; // SONAME
        if (dt.rpath > 0) nentries += 1; // RUNPATH
        if (elf_file.getSectionByName(".init") != null) nentries += 1; // INIT
        if (elf_file.getSectionByName(".fini") != null) nentries += 1; // FINI
        if (elf_file.getSectionByName(".init_array") != null) nentries += 2; // INIT_ARRAY
        if (elf_file.getSectionByName(".fini_array") != null) nentries += 2; // FINI_ARRAY
        if (elf_file.rela_dyn_sect_index != null) nentries += 3; // RELA
        if (elf_file.rela_plt_sect_index != null) nentries += 3; // JMPREL
        if (elf_file.got_plt_sect_index != null) nentries += 1; // PLTGOT
        nentries += 1; // HASH
        if (elf_file.gnu_hash_sect_index != null) nentries += 1; // GNU_HASH
        if (elf_file.has_text_reloc) nentries += 1; // TEXTREL
        nentries += 1; // SYMTAB
        nentries += 1; // SYMENT
        nentries += 1; // STRTAB
        nentries += 1; // STRSZ
        if (elf_file.versym_sect_index != null) nentries += 1; // VERSYM
        if (elf_file.verneed_sect_index != null) nentries += 2; // VERNEED
        if (dt.getFlags(elf_file) != null) nentries += 1; // FLAGS
        if (dt.getFlags1(elf_file) != null) nentries += 1; // FLAGS_1
        if (!is_shared) nentries += 1; // DEBUG
        nentries += 1; // NULL
        return nentries * @sizeOf(elf.Elf64_Dyn);
    }

    pub fn write(dt: DynamicSection, elf_file: *Elf, writer: anytype) !void {
        const is_shared = elf_file.options.shared;

        // NEEDED
        for (dt.needed.items) |off| {
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_NEEDED, .d_val = off });
        }

        if (dt.soname) |off| {
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_SONAME, .d_val = off });
        }

        // RUNPATH
        // TODO add option in Options to revert to old RPATH tag
        if (dt.rpath > 0) {
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_RUNPATH, .d_val = dt.rpath });
        }

        // INIT
        if (elf_file.getSectionByName(".init")) |shndx| {
            const addr = elf_file.sections.items(.shdr)[shndx].sh_addr;
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_INIT, .d_val = addr });
        }

        // FINI
        if (elf_file.getSectionByName(".fini")) |shndx| {
            const addr = elf_file.sections.items(.shdr)[shndx].sh_addr;
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_FINI, .d_val = addr });
        }

        // INIT_ARRAY
        if (elf_file.getSectionByName(".init_array")) |shndx| {
            const shdr = elf_file.sections.items(.shdr)[shndx];
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_INIT_ARRAY, .d_val = shdr.sh_addr });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_INIT_ARRAYSZ, .d_val = shdr.sh_size });
        }

        // FINI_ARRAY
        if (elf_file.getSectionByName(".fini_array")) |shndx| {
            const shdr = elf_file.sections.items(.shdr)[shndx];
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_FINI_ARRAY, .d_val = shdr.sh_addr });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_FINI_ARRAYSZ, .d_val = shdr.sh_size });
        }

        // RELA
        if (elf_file.rela_dyn_sect_index) |shndx| {
            const shdr = elf_file.sections.items(.shdr)[shndx];
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_RELA, .d_val = shdr.sh_addr });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_RELASZ, .d_val = shdr.sh_size });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_RELAENT, .d_val = shdr.sh_entsize });
        }

        // JMPREL
        if (elf_file.rela_plt_sect_index) |shndx| {
            const shdr = elf_file.sections.items(.shdr)[shndx];
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_JMPREL, .d_val = shdr.sh_addr });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_PLTRELSZ, .d_val = shdr.sh_size });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_PLTREL, .d_val = elf.DT_RELA });
        }

        // PLTGOT
        if (elf_file.got_plt_sect_index) |shndx| {
            const addr = elf_file.sections.items(.shdr)[shndx].sh_addr;
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_PLTGOT, .d_val = addr });
        }

        {
            assert(elf_file.hash_sect_index != null);
            const addr = elf_file.sections.items(.shdr)[elf_file.hash_sect_index.?].sh_addr;
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_HASH, .d_val = addr });
        }

        if (elf_file.gnu_hash_sect_index) |shndx| {
            const addr = elf_file.sections.items(.shdr)[shndx].sh_addr;
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_GNU_HASH, .d_val = addr });
        }

        // TEXTREL
        if (elf_file.has_text_reloc) {
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_TEXTREL, .d_val = 0 });
        }

        // SYMTAB + SYMENT
        {
            assert(elf_file.dynsymtab_sect_index != null);
            const shdr = elf_file.sections.items(.shdr)[elf_file.dynsymtab_sect_index.?];
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_SYMTAB, .d_val = shdr.sh_addr });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_SYMENT, .d_val = shdr.sh_entsize });
        }

        // STRTAB + STRSZ
        {
            assert(elf_file.dynstrtab_sect_index != null);
            const shdr = elf_file.sections.items(.shdr)[elf_file.dynstrtab_sect_index.?];
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_STRTAB, .d_val = shdr.sh_addr });
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_STRSZ, .d_val = shdr.sh_size });
        }

        // VERSYM
        if (elf_file.versym_sect_index) |shndx| {
            const addr = elf_file.sections.items(.shdr)[shndx].sh_addr;
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_VERSYM, .d_val = addr });
        }

        // VERNEED + VERNEEDNUM
        if (elf_file.verneed_sect_index) |shndx| {
            const addr = elf_file.sections.items(.shdr)[shndx].sh_addr;
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_VERNEED, .d_val = addr });
            try writer.writeStruct(elf.Elf64_Dyn{
                .d_tag = elf.DT_VERNEEDNUM,
                .d_val = elf_file.verneed.verneed.items.len,
            });
        }

        // FLAGS
        if (dt.getFlags(elf_file)) |flags| {
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_FLAGS, .d_val = flags });
        }
        // FLAGS_1
        if (dt.getFlags1(elf_file)) |flags_1| {
            try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_FLAGS_1, .d_val = flags_1 });
        }

        // DEBUG
        if (!is_shared) try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_DEBUG, .d_val = 0 });

        // NULL
        try writer.writeStruct(elf.Elf64_Dyn{ .d_tag = elf.DT_NULL, .d_val = 0 });
    }
};

pub const HashSection = struct {
    buffer: std.ArrayListUnmanaged(u8) = .{},

    pub fn deinit(hs: *HashSection, allocator: Allocator) void {
        hs.buffer.deinit(allocator);
    }

    pub fn generate(hs: *HashSection, elf_file: *Elf) !void {
        if (elf_file.dynsym.count() == 1) return;

        const gpa = elf_file.base.allocator;
        const nsyms = elf_file.dynsym.count();

        var buckets = try gpa.alloc(u32, nsyms);
        defer gpa.free(buckets);
        @memset(buckets, 0);

        var chains = try gpa.alloc(u32, nsyms);
        defer gpa.free(chains);
        @memset(chains, 0);

        for (elf_file.dynsym.entries.items, 1..) |entry, i| {
            const name = elf_file.getDynString(entry.off);
            const hash = hasher(name) % buckets.len;
            chains[@as(u32, @intCast(i))] = buckets[hash];
            buckets[hash] = @as(u32, @intCast(i));
        }

        try hs.buffer.ensureTotalCapacityPrecise(gpa, (2 + nsyms * 2) * 4);
        hs.buffer.writer(gpa).writeInt(u32, @as(u32, @intCast(nsyms)), .little) catch unreachable;
        hs.buffer.writer(gpa).writeInt(u32, @as(u32, @intCast(nsyms)), .little) catch unreachable;
        hs.buffer.writer(gpa).writeAll(mem.sliceAsBytes(buckets)) catch unreachable;
        hs.buffer.writer(gpa).writeAll(mem.sliceAsBytes(chains)) catch unreachable;
    }

    pub inline fn size(hs: HashSection) usize {
        return hs.buffer.items.len;
    }

    pub fn hasher(name: [:0]const u8) u32 {
        var h: u32 = 0;
        var g: u32 = 0;
        for (name) |c| {
            h = (h << 4) + c;
            g = h & 0xf0000000;
            if (g > 0) h ^= g >> 24;
            h &= ~g;
        }
        return h;
    }
};

pub const GnuHashSection = struct {
    num_buckets: u32 = 0,
    num_bloom: u32 = 1,
    num_exports: u32 = 0,

    pub const load_factor = 8;
    pub const header_size = 16;
    pub const bloom_shift = 26;

    fn getExports(elf_file: *Elf) []const DynsymSection.Entry {
        const start = for (elf_file.dynsym.entries.items, 0..) |dsym, i| {
            const sym = elf_file.getSymbol(dsym.ref).?;
            if (sym.flags.@"export") break i;
        } else elf_file.dynsym.entries.items.len;
        return elf_file.dynsym.entries.items[start..];
    }

    inline fn bitCeil(x: u64) u64 {
        if (@popCount(x) == 1) return x;
        return @as(u64, @intCast(@as(u128, 1) << (64 - @clz(x))));
    }

    pub fn calcSize(hash: *GnuHashSection, elf_file: *Elf) !void {
        hash.num_exports = @as(u32, @intCast(getExports(elf_file).len));
        if (hash.num_exports > 0) {
            const num_bits = hash.num_exports * 12;
            hash.num_bloom = @as(u32, @intCast(bitCeil(@divTrunc(num_bits, 64))));
        }
    }

    pub fn size(hash: GnuHashSection) usize {
        return header_size + hash.num_bloom * 8 + hash.num_buckets * 4 + hash.num_exports * 4;
    }

    pub fn write(hash: GnuHashSection, elf_file: *Elf, writer: anytype) !void {
        const exports = getExports(elf_file);
        const export_off = elf_file.dynsym.count() - hash.num_exports;

        var counting = std.io.countingWriter(writer);
        const cwriter = counting.writer();

        try cwriter.writeInt(u32, hash.num_buckets, .little);
        try cwriter.writeInt(u32, export_off, .little);
        try cwriter.writeInt(u32, hash.num_bloom, .little);
        try cwriter.writeInt(u32, bloom_shift, .little);

        const gpa = elf_file.base.allocator;
        const hashes = try gpa.alloc(u32, exports.len);
        defer gpa.free(hashes);
        const indices = try gpa.alloc(u32, exports.len);
        defer gpa.free(indices);

        // Compose and write the bloom filter
        const bloom = try gpa.alloc(u64, hash.num_bloom);
        defer gpa.free(bloom);
        @memset(bloom, 0);

        for (exports, 0..) |dsym, i| {
            const sym = elf_file.getSymbol(dsym.ref).?;
            const h = hasher(sym.getName(elf_file));
            hashes[i] = h;
            indices[i] = h % hash.num_buckets;
            const idx = @divTrunc(h, 64) % hash.num_bloom;
            bloom[idx] |= @as(u64, 1) << @as(u6, @intCast(h % 64));
            bloom[idx] |= @as(u64, 1) << @as(u6, @intCast((h >> bloom_shift) % 64));
        }

        try cwriter.writeAll(mem.sliceAsBytes(bloom));

        // Fill in the hash bucket indices
        const buckets = try gpa.alloc(u32, hash.num_buckets);
        defer gpa.free(buckets);
        @memset(buckets, 0);

        for (0..hash.num_exports) |i| {
            if (buckets[indices[i]] == 0) {
                buckets[indices[i]] = @as(u32, @intCast(i + export_off));
            }
        }

        try cwriter.writeAll(mem.sliceAsBytes(buckets));

        // Finally, write the hash table
        const table = try gpa.alloc(u32, hash.num_exports);
        defer gpa.free(table);
        @memset(table, 0);

        for (0..hash.num_exports) |i| {
            const h = hashes[i];
            if (i == exports.len - 1 or indices[i] != indices[i + 1]) {
                table[i] = h | 1;
            } else {
                table[i] = h & ~@as(u32, 1);
            }
        }

        try cwriter.writeAll(mem.sliceAsBytes(table));

        assert(counting.bytes_written == hash.size());
    }

    pub fn hasher(name: [:0]const u8) u32 {
        var h: u32 = 5381;
        for (name) |c| {
            h = (h << 5) +% h +% c;
        }
        return h;
    }
};

pub const DynsymSection = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},

    pub const Entry = struct {
        /// Ref of the symbol which gets privilege of getting a dynamic treatment
        ref: Elf.Ref,
        /// Offset into .dynstrtab
        off: u32,
    };

    pub fn deinit(dynsym: *DynsymSection, allocator: Allocator) void {
        dynsym.entries.deinit(allocator);
    }

    pub fn addSymbol(dynsym: *DynsymSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const gpa = elf_file.base.allocator;
        const index = @as(u32, @intCast(dynsym.entries.items.len + 1));
        const sym = elf_file.getSymbol(ref).?;
        sym.flags.has_dynamic = true;
        sym.addExtra(.{ .dynamic = index }, elf_file);
        const name = try elf_file.insertDynString(sym.getName(elf_file));
        try dynsym.entries.append(gpa, .{ .ref = ref, .off = name });
    }

    pub fn sort(dynsym: *DynsymSection, elf_file: *Elf) void {
        const Sort = struct {
            pub fn lessThan(ctx: *Elf, lhs: Entry, rhs: Entry) bool {
                const lhs_sym = ctx.getSymbol(lhs.ref).?;
                const rhs_sym = ctx.getSymbol(rhs.ref).?;

                if (lhs_sym.flags.@"export" != rhs_sym.flags.@"export") {
                    return rhs_sym.flags.@"export";
                }

                // TODO cache hash values
                const nbuckets = ctx.gnu_hash.num_buckets;
                const lhs_hash = GnuHashSection.hasher(lhs_sym.getName(ctx)) % nbuckets;
                const rhs_hash = GnuHashSection.hasher(rhs_sym.getName(ctx)) % nbuckets;

                if (lhs_hash == rhs_hash)
                    return lhs_sym.getExtra(ctx).dynamic < rhs_sym.getExtra(ctx).dynamic;
                return lhs_hash < rhs_hash;
            }
        };

        var num_exports: u32 = 0;
        for (dynsym.entries.items) |entry| {
            const sym = elf_file.getSymbol(entry.ref).?;
            if (sym.flags.@"export") num_exports += 1;
        }

        elf_file.gnu_hash.num_buckets = @divTrunc(num_exports, GnuHashSection.load_factor) + 1;

        std.mem.sort(Entry, dynsym.entries.items, elf_file, Sort.lessThan);

        for (dynsym.entries.items, 1..) |entry, index| {
            const sym = elf_file.getSymbol(entry.ref).?;
            var extra = sym.getExtra(elf_file);
            extra.dynamic = @as(u32, @intCast(index));
            sym.setExtra(extra, elf_file);
        }
    }

    pub fn size(dynsym: DynsymSection) usize {
        return dynsym.count() * @sizeOf(elf.Elf64_Sym);
    }

    pub fn count(dynsym: DynsymSection) u32 {
        return @as(u32, @intCast(dynsym.entries.items.len + 1));
    }

    pub fn write(dynsym: DynsymSection, elf_file: *Elf, writer: anytype) !void {
        try writer.writeStruct(Elf.null_sym);
        for (dynsym.entries.items) |entry| {
            const sym = elf_file.getSymbol(entry.ref).?;
            var out_sym: elf.Elf64_Sym = Elf.null_sym;
            sym.setOutputSym(elf_file, &out_sym);
            out_sym.st_name = entry.off;
            try writer.writeStruct(out_sym);
        }
    }
};

pub const VerneedSection = struct {
    verneed: std.ArrayListUnmanaged(elf.Elf64_Verneed) = .{},
    vernaux: std.ArrayListUnmanaged(elf.Elf64_Vernaux) = .{},
    index: elf.Elf64_Versym = elf.VER_NDX_GLOBAL + 1,

    pub fn deinit(vern: *VerneedSection, allocator: Allocator) void {
        vern.verneed.deinit(allocator);
        vern.vernaux.deinit(allocator);
    }

    pub fn generate(vern: *VerneedSection, elf_file: *Elf) !void {
        const dynsyms = elf_file.dynsym.entries.items;
        var versyms = elf_file.versym.items;

        const SymWithVersion = struct {
            idx: usize,
            shared: u32,
            version: elf.Elf64_Versym,

            fn getSoname(this: @This(), ctx: *Elf) []const u8 {
                const shared = ctx.getFile(this.shared).?.shared;
                return shared.getSoname();
            }

            fn getVersionString(this: @This(), ctx: *Elf) [:0]const u8 {
                const shared = ctx.getFile(this.shared).?.shared;
                return shared.getVersionString(this.version);
            }

            pub fn lessThan(ctx: *Elf, lhs: @This(), rhs: @This()) bool {
                if (lhs.shared == rhs.shared) return lhs.version < rhs.version;
                return mem.lessThan(u8, lhs.getSoname(ctx), rhs.getSoname(ctx));
            }
        };

        const gpa = elf_file.base.allocator;
        var verneed = std.ArrayList(SymWithVersion).init(gpa);
        defer verneed.deinit();
        try verneed.ensureTotalCapacity(dynsyms.len);

        for (dynsyms, 1..) |dynsym, i| {
            const symbol = elf_file.getSymbol(dynsym.ref).?;
            if (symbol.flags.import and symbol.ver_idx & elf.VERSYM_VERSION > elf.VER_NDX_GLOBAL) {
                const shared = symbol.getFile(elf_file).?.shared;
                verneed.appendAssumeCapacity(.{
                    .idx = i,
                    .shared = shared.index,
                    .version = symbol.ver_idx,
                });
            }
        }

        mem.sort(SymWithVersion, verneed.items, elf_file, SymWithVersion.lessThan);

        var last = verneed.items[0];
        var last_verneed = try vern.addVerneed(last.getSoname(elf_file), elf_file);
        var last_vernaux = try vern.addVernaux(last_verneed, last.getVersionString(elf_file), elf_file);
        versyms[last.idx] = last_vernaux.vna_other;

        for (verneed.items[1..]) |ver| {
            if (ver.shared == last.shared) {
                if (ver.version != last.version) {
                    last_vernaux = try vern.addVernaux(last_verneed, ver.getVersionString(elf_file), elf_file);
                }
            } else {
                last_verneed = try vern.addVerneed(ver.getSoname(elf_file), elf_file);
                last_vernaux = try vern.addVernaux(last_verneed, ver.getVersionString(elf_file), elf_file);
            }
            last = ver;
            versyms[ver.idx] = last_vernaux.vna_other;
        }

        // Fixup offsets
        var count: usize = 0;
        var verneed_off: u32 = 0;
        var vernaux_off: u32 = @as(u32, @intCast(vern.verneed.items.len)) * @sizeOf(elf.Elf64_Verneed);
        for (vern.verneed.items, 0..) |*vsym, vsym_i| {
            if (vsym_i < vern.verneed.items.len - 1) vsym.vn_next = @sizeOf(elf.Elf64_Verneed);
            vsym.vn_aux = vernaux_off - verneed_off;
            var inner_off: u32 = 0;
            for (vern.vernaux.items[count..][0..vsym.vn_cnt], 0..) |*vaux, vaux_i| {
                if (vaux_i < vsym.vn_cnt - 1) vaux.vna_next = @sizeOf(elf.Elf64_Vernaux);
                inner_off += @sizeOf(elf.Elf64_Vernaux);
            }
            vernaux_off += inner_off;
            verneed_off += @sizeOf(elf.Elf64_Verneed);
            count += vsym.vn_cnt;
        }
    }

    fn addVerneed(vern: *VerneedSection, soname: []const u8, elf_file: *Elf) !*elf.Elf64_Verneed {
        const gpa = elf_file.base.allocator;
        const sym = try vern.verneed.addOne(gpa);
        sym.* = .{
            .vn_version = 1,
            .vn_cnt = 0,
            .vn_file = try elf_file.insertDynString(soname),
            .vn_aux = 0,
            .vn_next = 0,
        };
        return sym;
    }

    fn addVernaux(
        vern: *VerneedSection,
        verneed_sym: *elf.Elf64_Verneed,
        version: [:0]const u8,
        elf_file: *Elf,
    ) !elf.Elf64_Vernaux {
        const gpa = elf_file.base.allocator;
        const sym = try vern.vernaux.addOne(gpa);
        sym.* = .{
            .vna_hash = HashSection.hasher(version),
            .vna_flags = 0,
            .vna_other = vern.index,
            .vna_name = try elf_file.insertDynString(version),
            .vna_next = 0,
        };
        verneed_sym.vn_cnt += 1;
        vern.index += 1;
        return sym.*;
    }

    pub fn size(vern: VerneedSection) usize {
        return vern.verneed.items.len * @sizeOf(elf.Elf64_Verneed) + vern.vernaux.items.len * @sizeOf(elf.Elf64_Vernaux);
    }

    pub fn write(vern: VerneedSection, writer: anytype) !void {
        try writer.writeAll(mem.sliceAsBytes(vern.verneed.items));
        try writer.writeAll(mem.sliceAsBytes(vern.vernaux.items));
    }
};

pub const GotSection = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},
    output_symtab_ctx: Elf.SymtabCtx = .{},
    tlsld_index: ?Index = null,
    flags: Flags = .{},

    pub const Index = u32;

    const Flags = packed struct {
        needs_rela: bool = false,
        needs_tlsld: bool = false,
    };

    const Tag = enum {
        got,
        tlsld,
        tlsgd,
        gottp,
        tlsdesc,
    };

    const Entry = struct {
        tag: Tag,
        ref: Elf.Ref,
        cell_index: Index,

        /// Returns how many indexes in the GOT this entry uses.
        pub inline fn len(entry: Entry) usize {
            return switch (entry.tag) {
                .got, .gottp => 1,
                .tlsld, .tlsgd, .tlsdesc => 2,
            };
        }

        pub fn getAddress(entry: Entry, elf_file: *Elf) i64 {
            const shdr = &elf_file.sections.items(.shdr)[elf_file.got_sect_index.?];
            return @as(i64, @intCast(shdr.sh_addr)) + entry.cell_index * @sizeOf(u64);
        }
    };

    pub fn deinit(got: *GotSection, allocator: Allocator) void {
        got.entries.deinit(allocator);
    }

    fn allocateEntry(got: *GotSection, allocator: Allocator) !Index {
        try got.entries.ensureUnusedCapacity(allocator, 1);
        const index = @as(Index, @intCast(got.entries.items.len));
        const entry = got.entries.addOneAssumeCapacity();
        const cell_index: Index = if (index > 0) blk: {
            const last = got.entries.items[index - 1];
            break :blk last.cell_index + @as(Index, @intCast(last.len()));
        } else 0;
        entry.* = .{ .tag = undefined, .ref = undefined, .cell_index = cell_index };
        return index;
    }

    pub fn addGotSymbol(got: *GotSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const index = try got.allocateEntry(elf_file.base.allocator);
        const entry = &got.entries.items[index];
        entry.tag = .got;
        entry.ref = ref;
        const symbol = elf_file.getSymbol(ref).?;
        if (symbol.flags.import or symbol.isIFunc(elf_file) or (elf_file.options.pic and !symbol.isAbs(elf_file)))
            got.flags.needs_rela = true;
        symbol.addExtra(.{ .got = index }, elf_file);
    }

    pub fn addTlsLdSymbol(got: *GotSection, elf_file: *Elf) !void {
        assert(got.flags.needs_tlsld);
        const index = try got.allocateEntry(elf_file.base.allocator);
        const entry = &got.entries.items[index];
        entry.tag = .tlsld;
        entry.ref = .{}; // unused
        got.flags.needs_rela = true;
        got.tlsld_index = index;
    }

    pub fn addTlsGdSymbol(got: *GotSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const index = try got.allocateEntry(elf_file.base.allocator);
        const entry = &got.entries.items[index];
        entry.tag = .tlsgd;
        entry.ref = ref;
        const symbol = elf_file.getSymbol(ref).?;
        if (symbol.flags.import or elf_file.options.shared) got.flags.needs_rela = true;
        symbol.addExtra(.{ .tlsgd = index }, elf_file);
    }

    pub fn addGotTpSymbol(got: *GotSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const index = try got.allocateEntry(elf_file.base.allocator);
        const entry = &got.entries.items[index];
        entry.tag = .gottp;
        entry.ref = ref;
        const symbol = elf_file.getSymbol(ref).?;
        if (symbol.flags.import or elf_file.options.shared) got.flags.needs_rela = true;
        symbol.addExtra(.{ .gottp = index }, elf_file);
    }

    pub fn addTlsDescSymbol(got: *GotSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const index = try got.allocateEntry(elf_file.base.allocator);
        const entry = &got.entries.items[index];
        entry.tag = .tlsdesc;
        entry.ref = ref;
        const symbol = elf_file.getSymbol(ref).?;
        got.flags.needs_rela = true;
        symbol.addExtra(.{ .tlsdesc = index }, elf_file);
    }

    pub fn size(got: GotSection) usize {
        var s: usize = 0;
        for (got.entries.items) |entry| {
            s += entry.len() * @sizeOf(u64);
        }
        return s;
    }

    pub fn write(got: GotSection, elf_file: *Elf, writer: anytype) !void {
        const is_shared = elf_file.options.shared;
        const apply_relocs = elf_file.options.apply_dynamic_relocs;

        for (got.entries.items) |entry| {
            const symbol = elf_file.getSymbol(entry.ref);
            switch (entry.tag) {
                .got => {
                    const value: i64 = blk: {
                        const value = symbol.?.getAddress(.{ .plt = false }, elf_file);
                        if (symbol.?.flags.import) break :blk 0;
                        if (symbol.?.isIFunc(elf_file))
                            break :blk if (apply_relocs) value else 0;
                        if (elf_file.options.pic and !symbol.?.isAbs(elf_file))
                            break :blk if (apply_relocs) value else 0;
                        break :blk value;
                    };
                    try writer.writeInt(u64, @bitCast(value), .little);
                },

                .tlsld => {
                    try writer.writeInt(u64, if (is_shared) @as(u64, 0) else 1, .little);
                    try writer.writeInt(u64, @as(u64, 0), .little);
                },

                .tlsgd => {
                    if (symbol.?.flags.import) {
                        try writer.writeInt(u64, 0, .little);
                        try writer.writeInt(u64, 0, .little);
                    } else {
                        try writer.writeInt(u64, if (is_shared) @as(u64, 0) else 1, .little);
                        const offset = symbol.?.getAddress(.{}, elf_file) - elf_file.getDtpAddress();
                        try writer.writeInt(u64, @bitCast(offset), .little);
                    }
                },

                .gottp => {
                    if (symbol.?.flags.import) {
                        try writer.writeInt(u64, 0, .little);
                    } else if (is_shared) {
                        const offset = if (apply_relocs)
                            symbol.?.getAddress(.{}, elf_file) - elf_file.getTlsAddress()
                        else
                            0;
                        try writer.writeInt(u64, @bitCast(offset), .little);
                    } else {
                        const offset = symbol.?.getAddress(.{}, elf_file) - elf_file.getTpAddress();
                        try writer.writeInt(u64, @bitCast(offset), .little);
                    }
                },

                .tlsdesc => {
                    if (symbol.?.flags.import) {
                        try writer.writeInt(u64, 0, .little);
                        try writer.writeInt(u64, 0, .little);
                    } else {
                        try writer.writeInt(u64, 0, .little);
                        const offset = if (apply_relocs)
                            symbol.?.getAddress(.{}, elf_file) - elf_file.getTlsAddress()
                        else
                            0;
                        try writer.writeInt(u64, @bitCast(offset), .little);
                    }
                },
            }
        }
    }

    pub fn addRela(got: GotSection, elf_file: *Elf) !void {
        const is_shared = elf_file.options.shared;
        const cpu_arch = elf_file.options.cpu_arch.?;
        try elf_file.rela_dyn.ensureUnusedCapacity(elf_file.base.allocator, got.numRela(elf_file));

        for (got.entries.items) |entry| {
            const symbol = elf_file.getSymbol(entry.ref);
            const extra = if (symbol) |s| s.getExtra(elf_file) else null;

            switch (entry.tag) {
                .got => {
                    const offset: u64 = @intCast(symbol.?.getGotAddress(elf_file));

                    if (symbol.?.flags.import) {
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset,
                            .sym = extra.?.dynamic,
                            .type = relocation.encode(.glob_dat, cpu_arch),
                        });
                        continue;
                    }

                    if (symbol.?.isIFunc(elf_file)) {
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset,
                            .type = relocation.encode(.irel, cpu_arch),
                            .addend = @intCast(symbol.?.getAddress(.{ .plt = false }, elf_file)),
                        });
                        continue;
                    }

                    if (elf_file.options.pic and !symbol.?.isAbs(elf_file)) {
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset,
                            .type = relocation.encode(.rel, cpu_arch),
                            .addend = @intCast(symbol.?.getAddress(.{ .plt = false }, elf_file)),
                        });
                    }
                },

                .tlsld => {
                    if (is_shared) {
                        const offset = entry.getAddress(elf_file);
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = @intCast(offset),
                            .type = relocation.encode(.dtpmod, cpu_arch),
                        });
                    }
                },

                .tlsgd => {
                    const offset: u64 = @intCast(symbol.?.getTlsGdAddress(elf_file));
                    if (symbol.?.flags.import) {
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset,
                            .sym = extra.?.dynamic,
                            .type = relocation.encode(.dtpmod, cpu_arch),
                        });
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset + 8,
                            .sym = extra.?.dynamic,
                            .type = relocation.encode(.dtpoff, cpu_arch),
                        });
                    } else if (is_shared) {
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset,
                            .sym = extra.?.dynamic,
                            .type = relocation.encode(.dtpmod, cpu_arch),
                        });
                    }
                },

                .gottp => {
                    const offset: u64 = @intCast(symbol.?.getGotTpAddress(elf_file));
                    if (symbol.?.flags.import) {
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset,
                            .sym = extra.?.dynamic,
                            .type = relocation.encode(.tpoff, cpu_arch),
                        });
                    } else if (is_shared) {
                        elf_file.addRelaDynAssumeCapacity(.{
                            .offset = offset,
                            .type = relocation.encode(.tpoff, cpu_arch),
                            .addend = @intCast(symbol.?.getAddress(.{}, elf_file) - elf_file.getTlsAddress()),
                        });
                    }
                },

                .tlsdesc => {
                    const offset = symbol.?.getTlsDescAddress(elf_file);
                    elf_file.addRelaDynAssumeCapacity(.{
                        .offset = @intCast(offset),
                        .sym = if (symbol.?.flags.import) extra.?.dynamic else 0,
                        .type = relocation.encode(.tlsdesc, cpu_arch),
                        .addend = if (symbol.?.flags.import) 0 else @intCast(symbol.?.getAddress(.{}, elf_file) - elf_file.getTlsAddress()),
                    });
                },
            }
        }
    }

    pub fn numRela(got: GotSection, elf_file: *Elf) usize {
        const is_shared = elf_file.options.shared;
        var num: usize = 0;
        for (got.entries.items) |entry| {
            const symbol = elf_file.getSymbol(entry.ref);
            switch (entry.tag) {
                .got => if (symbol.?.flags.import or
                    symbol.?.isIFunc(elf_file) or (elf_file.options.pic and !symbol.?.isAbs(elf_file)))
                {
                    num += 1;
                },

                .tlsld => if (is_shared) {
                    num += 1;
                },

                .tlsgd => if (symbol.?.flags.import) {
                    num += 2;
                } else if (is_shared) {
                    num += 1;
                },

                .gottp => if (symbol.?.flags.import or is_shared) {
                    num += 1;
                },

                .tlsdesc => num += 1,
            }
        }
        return num;
    }

    pub fn calcSymtabSize(got: *GotSection, elf_file: *Elf) void {
        if (elf_file.options.strip_all) return;
        got.output_symtab_ctx.nlocals = @as(u32, @intCast(got.entries.items.len));
        for (got.entries.items) |entry| {
            const symbol_name = if (elf_file.getSymbol(entry.ref)) |sym|
                sym.getName(elf_file)
            else
                "";
            got.output_symtab_ctx.strsize += @as(u32, @intCast(symbol_name.len + @tagName(entry.tag).len + 1 + 1));
        }
    }

    pub fn writeSymtab(got: GotSection, elf_file: *Elf) void {
        if (elf_file.options.strip_all) return;

        for (got.entries.items, got.output_symtab_ctx.ilocal..) |entry, ilocal| {
            const symbol = elf_file.getSymbol(entry.ref);
            const symbol_name = if (symbol) |s| s.getName(elf_file) else "";
            const st_name = @as(u32, @intCast(elf_file.strtab.items.len));
            elf_file.strtab.appendSliceAssumeCapacity(symbol_name);
            elf_file.strtab.appendAssumeCapacity('$');
            elf_file.strtab.appendSliceAssumeCapacity(@tagName(entry.tag));
            elf_file.strtab.appendAssumeCapacity(0);
            const st_value = entry.getAddress(elf_file);
            const st_size: u64 = entry.len() * @sizeOf(u64);
            elf_file.symtab.items[ilocal] = .{
                .st_name = st_name,
                .st_info = elf.STT_OBJECT,
                .st_other = 0,
                .st_shndx = @intCast(elf_file.got_sect_index.?),
                .st_value = @intCast(st_value),
                .st_size = st_size,
            };
        }
    }

    const FormatCtx = struct {
        got: GotSection,
        elf_file: *Elf,
    };

    pub fn fmt(got: GotSection, elf_file: *Elf) std.fmt.Formatter(format2) {
        return .{ .data = .{ .got = got, .elf_file = elf_file } };
    }

    pub fn format2(
        ctx: FormatCtx,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = unused_fmt_string;
        for (ctx.got.entries.items) |entry| {
            const symbol = ctx.elf_file.getSymbol(entry.ref).?;
            try writer.print("  {d}@0x{x} => {}@0x{x} ({s})\n", .{
                entry.cell_index,
                entry.getAddress(ctx.elf_file),
                entry.ref,
                symbol.getAddress(.{}, ctx.elf_file),
                symbol.getName(ctx.elf_file),
            });
        }
    }
};

pub const PltSection = struct {
    symbols: std.ArrayListUnmanaged(Elf.Ref) = .{},
    output_symtab_ctx: Elf.SymtabCtx = .{},

    pub fn deinit(plt: *PltSection, allocator: Allocator) void {
        plt.symbols.deinit(allocator);
    }

    pub fn addSymbol(plt: *PltSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const index = @as(u32, @intCast(plt.symbols.items.len));
        const symbol = elf_file.getSymbol(ref).?;
        symbol.addExtra(.{ .plt = index }, elf_file);
        try plt.symbols.append(elf_file.base.allocator, ref);
    }

    pub fn size(plt: PltSection, elf_file: *Elf) usize {
        const cpu_arch = elf_file.options.cpu_arch.?;
        return preambleSize(cpu_arch) + plt.symbols.items.len * entrySize(cpu_arch);
    }

    pub fn preambleSize(cpu_arch: std.Target.Cpu.Arch) usize {
        return switch (cpu_arch) {
            .x86_64 => 32,
            .aarch64 => 8 * @sizeOf(u32),
            else => @panic("TODO implement preambleSize for this cpu arch"),
        };
    }

    pub fn entrySize(cpu_arch: std.Target.Cpu.Arch) usize {
        return switch (cpu_arch) {
            .x86_64 => 16,
            .aarch64 => 4 * @sizeOf(u32),
            else => @panic("TODO implement entrySize for this cpu arch"),
        };
    }

    pub fn write(plt: PltSection, elf_file: *Elf, writer: anytype) !void {
        const cpu_arch = elf_file.options.cpu_arch.?;
        switch (cpu_arch) {
            .x86_64 => try x86_64.write(plt, elf_file, writer),
            .aarch64 => try aarch64.write(plt, elf_file, writer),
            else => {
                elf_file.base.fatal("TODO write .plt for arch {s}", .{@tagName(cpu_arch)});
                return error.UnsupportedCpuArch;
            },
        }
    }

    pub fn addRela(plt: PltSection, elf_file: *Elf) !void {
        try elf_file.rela_plt.ensureUnusedCapacity(elf_file.base.allocator, plt.numRela());
        for (plt.symbols.items) |ref| {
            const sym = elf_file.getSymbol(ref).?;
            assert(sym.flags.import);
            const extra = sym.getExtra(elf_file);
            const r_offset: u64 = @intCast(sym.getGotPltAddress(elf_file));
            const r_sym: u64 = extra.dynamic;
            const r_type = relocation.encode(.jump_slot, elf_file.options.cpu_arch.?);
            elf_file.rela_plt.appendAssumeCapacity(.{
                .r_offset = r_offset,
                .r_info = (r_sym << 32) | r_type,
                .r_addend = 0,
            });
        }
    }

    pub fn numRela(plt: PltSection) usize {
        return plt.symbols.items.len;
    }

    pub fn calcSymtabSize(plt: *PltSection, elf_file: *Elf) void {
        if (elf_file.options.strip_all) return;

        plt.output_symtab_ctx.nlocals = @as(u32, @intCast(plt.symbols.items.len));
        for (plt.symbols.items) |ref| {
            const sym = elf_file.getSymbol(ref).?;
            plt.output_symtab_ctx.strsize += @as(u32, @intCast(sym.getName(elf_file).len + "$plt".len + 1));
        }
    }

    pub fn writeSymtab(plt: PltSection, elf_file: *Elf) void {
        if (elf_file.options.strip_all) return;
        const cpu_arch = elf_file.options.cpu_arch.?;

        for (plt.symbols.items, plt.output_symtab_ctx.ilocal..) |ref, ilocal| {
            const sym = elf_file.getSymbol(ref).?;
            const st_name = @as(u32, @intCast(elf_file.strtab.items.len));
            elf_file.strtab.appendSliceAssumeCapacity(sym.getName(elf_file));
            elf_file.strtab.appendSliceAssumeCapacity("$plt");
            elf_file.strtab.appendAssumeCapacity(0);
            elf_file.symtab.items[ilocal] = .{
                .st_name = st_name,
                .st_info = elf.STT_FUNC,
                .st_other = 0,
                .st_shndx = @intCast(elf_file.plt_sect_index.?),
                .st_value = @intCast(sym.getPltAddress(elf_file)),
                .st_size = entrySize(cpu_arch),
            };
        }
    }

    const FormatCtx = struct {
        plt: PltSection,
        elf_file: *Elf,
    };

    pub fn fmt(plt: PltSection, elf_file: *Elf) std.fmt.Formatter(format2) {
        return .{ .data = .{ .plt = plt, .elf_file = elf_file } };
    }

    pub fn format2(
        ctx: FormatCtx,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = unused_fmt_string;
        const plt = ctx.plt;
        const elf_file = ctx.elf_file;
        for (plt.symbols.items, 0..) |ref, i| {
            const symbol = elf_file.getSymbol(ref).?;
            try writer.print("  {d}@0x{x} => {} ({s})\n", .{
                i,
                symbol.getAddress(.{}, elf_file),
                ref,
                symbol.getName(elf_file),
            });
        }
    }

    const x86_64 = struct {
        fn write(plt: PltSection, elf_file: *Elf, writer: anytype) !void {
            const plt_addr = elf_file.sections.items(.shdr)[elf_file.plt_sect_index.?].sh_addr;
            const got_plt_addr = elf_file.sections.items(.shdr)[elf_file.got_plt_sect_index.?].sh_addr;
            var preamble = [_]u8{
                0xf3, 0x0f, 0x1e, 0xfa, // endbr64
                0x41, 0x53, // push r11
                0xff, 0x35, 0x00, 0x00, 0x00, 0x00, // push qword ptr [rip] -> .got.plt[1]
                0xff, 0x25, 0x00, 0x00, 0x00, 0x00, // jmp qword ptr [rip] -> .got.plt[2]
            };
            var disp = @as(i64, @intCast(got_plt_addr + 8)) - @as(i64, @intCast(plt_addr + 8)) - 4;
            mem.writeInt(i32, preamble[8..][0..4], @as(i32, @intCast(disp)), .little);
            disp = @as(i64, @intCast(got_plt_addr + 16)) - @as(i64, @intCast(plt_addr + 14)) - 4;
            mem.writeInt(i32, preamble[14..][0..4], @as(i32, @intCast(disp)), .little);
            try writer.writeAll(&preamble);
            try writer.writeByteNTimes(0xcc, preambleSize(.x86_64) - preamble.len);

            for (plt.symbols.items, 0..) |ref, i| {
                const sym = elf_file.getSymbol(ref).?;
                const target_addr = sym.getGotPltAddress(elf_file);
                const source_addr = sym.getPltAddress(elf_file);
                disp = @as(i64, @intCast(target_addr)) - @as(i64, @intCast(source_addr + 12)) - 4;
                var entry = [_]u8{
                    0xf3, 0x0f, 0x1e, 0xfa, // endbr64
                    0x41, 0xbb, 0x00, 0x00, 0x00, 0x00, // mov r11d, N
                    0xff, 0x25, 0x00, 0x00, 0x00, 0x00, // jmp qword ptr [rip] -> .got.plt[N]
                };
                mem.writeInt(i32, entry[6..][0..4], @as(i32, @intCast(i)), .little);
                mem.writeInt(i32, entry[12..][0..4], @as(i32, @intCast(disp)), .little);
                try writer.writeAll(&entry);
            }
        }
    };

    const aarch64 = struct {
        fn write(plt: PltSection, elf_file: *Elf, writer: anytype) !void {
            {
                const plt_addr: i64 = @intCast(elf_file.sections.items(.shdr)[elf_file.plt_sect_index.?].sh_addr);
                const got_plt_addr: i64 = @intCast(elf_file.sections.items(.shdr)[elf_file.got_plt_sect_index.?].sh_addr);
                // TODO: relax if possible
                // .got.plt[2]
                const pages = try aarch64_util.calcNumberOfPages(plt_addr + 4, got_plt_addr + 16);
                const ldr_off = try math.divExact(u12, @truncate(@as(u64, @bitCast(got_plt_addr + 16))), 8);
                const add_off: u12 = @truncate(@as(u64, @bitCast(got_plt_addr + 16)));

                const preamble = &[_]Instruction{
                    Instruction.stp(
                        .x16,
                        .x30,
                        Register.sp,
                        Instruction.LoadStorePairOffset.pre_index(-16),
                    ),
                    Instruction.adrp(.x16, pages),
                    Instruction.ldr(.x17, .x16, Instruction.LoadStoreOffset.imm(ldr_off)),
                    Instruction.add(.x16, .x16, add_off, false),
                    Instruction.br(.x17),
                    Instruction.nop(),
                    Instruction.nop(),
                    Instruction.nop(),
                };
                comptime assert(preamble.len == 8);
                for (preamble) |inst| {
                    try writer.writeInt(u32, inst.toU32(), .little);
                }
            }

            for (plt.symbols.items) |ref| {
                const sym = elf_file.getSymbol(ref).?;
                const target_addr = sym.getGotPltAddress(elf_file);
                const source_addr = sym.getPltAddress(elf_file);
                const pages = try aarch64_util.calcNumberOfPages(source_addr, target_addr);
                const ldr_off = try math.divExact(u12, @truncate(@as(u64, @bitCast(target_addr))), 8);
                const add_off: u12 = @truncate(@as(u64, @intCast(target_addr)));
                const insts = &[_]Instruction{
                    Instruction.adrp(.x16, pages),
                    Instruction.ldr(.x17, .x16, Instruction.LoadStoreOffset.imm(ldr_off)),
                    Instruction.add(.x16, .x16, add_off, false),
                    Instruction.br(.x17),
                };
                comptime assert(insts.len == 4);
                for (insts) |inst| {
                    try writer.writeInt(u32, inst.toU32(), .little);
                }
            }
        }

        const aarch64_util = @import("../aarch64.zig");
        const Instruction = aarch64_util.Instruction;
        const Register = aarch64_util.Register;
    };
};

pub const GotPltSection = struct {
    pub const preamble_size = 24;

    pub fn size(got_plt: GotPltSection, elf_file: *Elf) usize {
        _ = got_plt;
        return preamble_size + elf_file.plt.symbols.items.len * 8;
    }

    pub fn write(got_plt: GotPltSection, elf_file: *Elf, writer: anytype) !void {
        _ = got_plt;
        {
            // [0]: _DYNAMIC
            const symbol = elf_file.getInternalObject().?.getDynamicSymbol(elf_file).?;
            try writer.writeInt(u64, @bitCast(symbol.getAddress(.{}, elf_file)), .little);
        }
        // [1]: 0x0
        // [2]: 0x0
        try writer.writeInt(u64, 0x0, .little);
        try writer.writeInt(u64, 0x0, .little);
        if (elf_file.plt_sect_index) |shndx| {
            const plt_addr = elf_file.sections.items(.shdr)[shndx].sh_addr;
            for (0..elf_file.plt.symbols.items.len) |_| {
                // [N]: .plt
                try writer.writeInt(u64, plt_addr, .little);
            }
        }
    }
};

pub const PltGotSection = struct {
    symbols: std.ArrayListUnmanaged(Elf.Ref) = .{},
    output_symtab_ctx: Elf.SymtabCtx = .{},

    pub fn deinit(plt_got: *PltGotSection, allocator: Allocator) void {
        plt_got.symbols.deinit(allocator);
    }

    pub fn addSymbol(plt_got: *PltGotSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const index = @as(u32, @intCast(plt_got.symbols.items.len));
        const symbol = elf_file.getSymbol(ref).?;
        symbol.addExtra(.{ .plt_got = index }, elf_file);
        symbol.flags.plt = true;
        symbol.flags.got = true;
        try plt_got.symbols.append(elf_file.base.allocator, ref);
    }

    pub fn size(plt_got: PltGotSection, elf_file: *Elf) usize {
        return plt_got.symbols.items.len * entrySize(elf_file.options.cpu_arch.?);
    }

    pub fn entrySize(cpu_arch: std.Target.Cpu.Arch) usize {
        return switch (cpu_arch) {
            .x86_64 => 16,
            .aarch64 => 4 * @sizeOf(u32),
            else => @panic("TODO implement PltGotSection.entrySize for this arch"),
        };
    }

    pub fn write(plt_got: PltGotSection, elf_file: *Elf, writer: anytype) !void {
        const cpu_arch = elf_file.options.cpu_arch.?;
        switch (cpu_arch) {
            .x86_64 => try x86_64.write(plt_got, elf_file, writer),
            .aarch64 => try aarch64.write(plt_got, elf_file, writer),
            else => {
                elf_file.base.fatal("TODO write .plt.got for arch {s}", .{@tagName(cpu_arch)});
                return error.UnsupportedCpuArch;
            },
        }
    }

    pub fn calcSymtabSize(plt_got: *PltGotSection, elf_file: *Elf) void {
        if (elf_file.options.strip_all) return;

        plt_got.output_symtab_ctx.nlocals = @as(u32, @intCast(plt_got.symbols.items.len));
        for (plt_got.symbols.items) |ref| {
            const sym = elf_file.getSymbol(ref).?;
            plt_got.output_symtab_ctx.strsize += @as(u32, @intCast(sym.getName(elf_file).len + "$pltgot".len + 1));
        }
    }

    pub fn writeSymtab(plt_got: PltGotSection, elf_file: *Elf) void {
        if (elf_file.options.strip_all) return;

        for (plt_got.symbols.items, plt_got.output_symtab_ctx.ilocal..) |ref, ilocal| {
            const sym = elf_file.getSymbol(ref).?;
            const st_name = @as(u32, @intCast(elf_file.strtab.items.len));
            elf_file.strtab.appendSliceAssumeCapacity(sym.getName(elf_file));
            elf_file.strtab.appendSliceAssumeCapacity("$pltgot");
            elf_file.strtab.appendAssumeCapacity(0);
            elf_file.symtab.items[ilocal] = .{
                .st_name = st_name,
                .st_info = elf.STT_FUNC,
                .st_other = 0,
                .st_shndx = @intCast(elf_file.plt_got_sect_index.?),
                .st_value = @intCast(sym.getPltGotAddress(elf_file)),
                .st_size = 16,
            };
        }
    }

    const x86_64 = struct {
        fn write(plt_got: PltGotSection, elf_file: *Elf, writer: anytype) !void {
            for (plt_got.symbols.items) |ref| {
                const sym = elf_file.getSymbol(ref).?;
                const target_addr = sym.getGotAddress(elf_file);
                const source_addr = sym.getPltGotAddress(elf_file);
                const disp = @as(i64, @intCast(target_addr)) - @as(i64, @intCast(source_addr + 6)) - 4;
                var entry = [_]u8{
                    0xf3, 0x0f, 0x1e, 0xfa, // endbr64
                    0xff, 0x25, 0x00, 0x00, 0x00, 0x00, // jmp qword ptr [rip] -> .got[N]
                    0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc,
                };
                mem.writeInt(i32, entry[6..][0..4], @as(i32, @intCast(disp)), .little);
                try writer.writeAll(&entry);
            }
        }
    };

    const aarch64 = struct {
        fn write(plt_got: PltGotSection, elf_file: *Elf, writer: anytype) !void {
            for (plt_got.symbols.items) |ref| {
                const sym = elf_file.getSymbol(ref).?;
                const target_addr = sym.getGotAddress(elf_file);
                const source_addr = sym.getPltGotAddress(elf_file);
                const pages = try aarch64_util.calcNumberOfPages(source_addr, target_addr);
                const off = try math.divExact(u12, @truncate(@as(u64, @intCast(target_addr))), 8);
                const insts = &[_]Instruction{
                    Instruction.adrp(.x16, pages),
                    Instruction.ldr(.x17, .x16, Instruction.LoadStoreOffset.imm(off)),
                    Instruction.br(.x17),
                    Instruction.nop(),
                };
                comptime assert(insts.len == 4);
                for (insts) |inst| {
                    try writer.writeInt(u32, inst.toU32(), .little);
                }
            }
        }

        const aarch64_util = @import("../aarch64.zig");
        const Instruction = aarch64_util.Instruction;
        const Register = aarch64_util.Register;
    };
};

pub const CopyRelSection = struct {
    symbols: std.ArrayListUnmanaged(Elf.Ref) = .{},

    pub fn deinit(copy_rel: *CopyRelSection, allocator: Allocator) void {
        copy_rel.symbols.deinit(allocator);
    }

    pub fn addSymbol(copy_rel: *CopyRelSection, ref: Elf.Ref, elf_file: *Elf) !void {
        const index = @as(u32, @intCast(copy_rel.symbols.items.len));
        const symbol = elf_file.getSymbol(ref).?;
        symbol.flags.import = true;
        symbol.flags.@"export" = true;
        symbol.flags.has_copy_rel = true;
        symbol.flags.weak = false;
        symbol.addExtra(.{ .copy_rel = index }, elf_file);
        try copy_rel.symbols.append(elf_file.base.allocator, ref);

        const shared = symbol.getFile(elf_file).?.shared;
        if (shared.aliases == null) {
            try shared.initSymbolAliases(elf_file);
        }

        const aliases = shared.getSymbolAliases(ref.index, elf_file);
        for (aliases) |alias| {
            if (alias == ref.index) continue;
            const alias_sym = &shared.symbols.items[alias];
            alias_sym.flags.import = true;
            alias_sym.flags.@"export" = true;
            alias_sym.flags.has_copy_rel = true;
            alias_sym.flags.copy_rel = true;
            alias_sym.flags.weak = false;
            try elf_file.dynsym.addSymbol(.{ .index = alias, .file = shared.index }, elf_file);
        }
    }

    pub fn calcSectionSize(copy_rel: CopyRelSection, shndx: u32, elf_file: *Elf) !void {
        const shdr = &elf_file.sections.items(.shdr)[shndx];
        for (copy_rel.symbols.items) |ref| {
            const symbol = elf_file.getSymbol(ref).?;
            const shared = symbol.getFile(elf_file).?.shared;
            const alignment = try symbol.getAlignment(elf_file);
            symbol.value = @intCast(mem.alignForward(u64, shdr.sh_size, alignment));
            shdr.sh_addralign = @max(shdr.sh_addralign, alignment);
            shdr.sh_size = @as(u64, @intCast(symbol.value)) + symbol.getElfSym(elf_file).st_size;

            const aliases = shared.getSymbolAliases(ref.index, elf_file);
            for (aliases) |alias| {
                if (alias == ref.index) continue;
                const alias_sym = &shared.symbols.items[alias];
                alias_sym.value = symbol.value;
            }
        }
    }

    pub fn addRela(copy_rel: CopyRelSection, elf_file: *Elf) !void {
        try elf_file.rela_dyn.ensureUnusedCapacity(elf_file.base.allocator, copy_rel.numRela());
        for (copy_rel.symbols.items) |ref| {
            const sym = elf_file.getSymbol(ref).?;
            assert(sym.flags.import and sym.flags.copy_rel);
            const extra = sym.getExtra(elf_file);
            elf_file.addRelaDynAssumeCapacity(.{
                .offset = @intCast(sym.getAddress(.{}, elf_file)),
                .sym = extra.dynamic,
                .type = relocation.encode(.copy, elf_file.options.cpu_arch.?),
            });
        }
    }

    pub fn numRela(copy_rel: CopyRelSection) usize {
        return copy_rel.symbols.items.len;
    }
};

pub const ComdatGroupSection = struct {
    shndx: u32,
    cg_ref: Elf.Ref,

    fn getComdatGroup(cgs: ComdatGroupSection, elf_file: *Elf) *Elf.ComdatGroup {
        const cg_file = elf_file.getFile(cgs.cg_ref.file).?;
        return cg_file.object.getComdatGroup(cgs.cg_ref.index);
    }

    pub fn getSymbol(cgs: ComdatGroupSection, elf_file: *Elf) *Symbol {
        const cg = cgs.getComdatGroup(elf_file);
        const object = cg.getFile(elf_file).object;
        const shdr = object.shdrs.items[cg.shndx];
        return &object.symbols.items[shdr.sh_info];
    }

    pub fn size(cgs: ComdatGroupSection, elf_file: *Elf) usize {
        const cg = cgs.getComdatGroup(elf_file);
        const members = cg.getComdatGroupMembers(elf_file);
        return (members.len + 1) * @sizeOf(u32);
    }

    pub fn write(cgs: ComdatGroupSection, elf_file: *Elf, writer: anytype) !void {
        const cg = cgs.getComdatGroup(elf_file);
        const object = cg.getFile(elf_file).object;
        const members = cg.getComdatGroupMembers(elf_file);
        try writer.writeInt(u32, elf.GRP_COMDAT, .little);
        for (members) |shndx| {
            const shdr = object.shdrs.items[shndx];
            switch (shdr.sh_type) {
                elf.SHT_RELA => {
                    const atom_index = object.atoms_indexes.items[shdr.sh_info];
                    const atom = object.getAtom(atom_index).?;
                    const rela_shndx = for (elf_file.sections.items(.shdr), 0..) |rela_shdr, rela_shndx| {
                        if (rela_shdr.sh_type == elf.SHT_RELA and
                            atom.out_shndx == rela_shdr.sh_info)
                            break rela_shndx;
                    } else unreachable;
                    try writer.writeInt(u32, @intCast(rela_shndx), .little);
                },
                else => {
                    const atom_index = object.atoms_indexes.items[shndx];
                    const atom = object.getAtom(atom_index).?;
                    try writer.writeInt(u32, atom.out_shndx, .little);
                },
            }
        }
    }
};

const assert = std.debug.assert;
const elf = std.elf;
const math = std.math;
const mem = std.mem;
const relocation = @import("relocation.zig");
const std = @import("std");

const Allocator = mem.Allocator;
const Elf = @import("../Elf.zig");
const File = @import("file.zig").File;
const SharedObject = @import("SharedObject.zig");
const Symbol = @import("Symbol.zig");
