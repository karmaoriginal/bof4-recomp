// Mod Loader for Breath of Fire IV (code patches, overlay hooks, GameShark,
// disc file overrides, native code overrides, and HD PNG texture packs).
//
// Directory layout (relative to working directory / Android data_dir):
//   mods/
//     <mod_folder>/
//       mod.ini            (optional metadata: name, author, version, enabled, priority)
//       code.txt           (optional MIPS / RAM / overlay-safe / GameShark code patches)
//       patches/*.txt      (additional code patch files)
//       textures/*.png     (1x or HD 2x/4x RGBA texture replacements)
//       disc/<ISO_PATH>    (PS1 CD-ROM file overrides served via spu.sector_hook)
//       native/bof4_arm64.native | native/bof4.native (optional compiled native override)
//     dumped_textures/     (auto-populated when Dump Textures is enabled in Quick Menu)
package qol

import "core:encoding/ini"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "ps:core/disc"
import cpu "ps:psx/cpu"
import host "ps:psx/host"
import render "ps:psx/render"
import spu "ps:psx/spu"

MODS_ROOT :: "mods"

@(private)
Mod_Patch_Kind :: enum u8 {
	Write8,
	Write16,
	Write32,
	Bytes,
}

@(private)
Mod_Cond_Kind :: enum u8 {
	None,
	Eq16,
	Ne16,
	Eq32,
	Ne32,
}

@(private)
Mod_Code_Patch :: struct {
	mod_idx:    int,
	kind:       Mod_Patch_Kind,
	cond:       Mod_Cond_Kind,
	cond_addr:  u32,
	cond_val:   u32,
	addr:       u32,
	val:        u32,
	bytes:      []u8,
	once:       bool,
	applied:    bool,
}

@(private)
Mod_Disc_Override :: struct {
	lba_start: u32,
	lba_end:   u32, // exclusive
	data:      []u8,
	iso_path:  string,
}

@(private)
Mod_Entry :: struct {
	folder:      string,
	dir:         string,
	name:        string,
	author:      string,
	version:     string,
	description: string,
	enabled:     bool,
	priority:    int,
	patch_count: int,
	tex_count:   int,
	disc_count:  int,
}

@(private)
mods_state: struct {
	initialized:   bool,
	mods:          [dynamic]Mod_Entry,
	patches:       [dynamic]Mod_Code_Patch,
	disc_files:    [dynamic]Mod_Disc_Override,
	prev_sector:   proc(lba: u32) -> []u8,
	sector_hooked: bool,
	loaded_tex:    int,
	active_mods:   int,
}

// Check enabled mods for an optional native code blob override before psx.run.
mods_find_native_override :: proc() -> string {
	if !config.mods_enabled || !os.exists(MODS_ROOT) {
		return ""
	}
	entries, err := os.read_all_directory_by_path(MODS_ROOT, context.temp_allocator)
	if err != nil {
		return ""
	}
	best_prio := min(int)
	best_path := ""
	for e in entries {
		if e.type != .Directory || is_ignored_mod_dir(e.name) {
			continue
		}
		meta := read_mod_manifest(e.fullpath, e.name, context.temp_allocator)
		if !meta.enabled {
			continue
		}
		cand := ""
		when ODIN_ARCH == .arm64 {
			p1, _ := filepath.join({e.fullpath, "native", "bof4_arm64.native"}, context.temp_allocator)
			p2, _ := filepath.join({e.fullpath, "native", "bof4.native"}, context.temp_allocator)
			if os.exists(p1) {
				cand = p1
			} else if os.exists(p2) {
				cand = p2
			}
		} else {
			p2, _ := filepath.join({e.fullpath, "native", "bof4.native"}, context.temp_allocator)
			if os.exists(p2) {
				cand = p2
			}
		}
		if cand != "" && meta.priority >= best_prio {
			best_prio = meta.priority
			best_path = cand
		}
	}
	return best_path
}

@(private)
mods_init :: proc() {
	if mods_state.initialized {
		return
	}
	mods_state.initialized = true
	if !mods_state.sector_hooked {
		mods_state.prev_sector = spu.sector_hook
		spu.sector_hook = mods_sector_hook
		mods_state.sector_hooked = true
	}
	mods_reload()
}

@(private)
mods_reload :: proc() {
	// Free previous state
	for p in mods_state.patches {
		delete(p.bytes)
	}
	clear(&mods_state.patches)
	for df in mods_state.disc_files {
		delete(df.data)
		delete(df.iso_path)
	}
	clear(&mods_state.disc_files)
	for m in mods_state.mods {
		delete(m.folder)
		delete(m.dir)
		delete(m.name)
		delete(m.author)
		delete(m.version)
		delete(m.description)
	}
	clear(&mods_state.mods)
	mods_state.loaded_tex = 0
	mods_state.active_mods = 0

	when PS_ANDROID_PATCH {
		render.mod_tex_clear()
		render.mod_tex_enabled = config.mods_enabled && config.mods_textures
		render.mod_tex_dump = config.mods_dump_textures
	} else {
		_ = render.VRAM_W
	}

	if !os.exists(MODS_ROOT) {
		return
	}
	entries, err := os.read_all_directory_by_path(MODS_ROOT, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		if e.type != .Directory || is_ignored_mod_dir(e.name) {
			continue
		}
		m := read_mod_manifest(e.fullpath, e.name, context.allocator)
		append(&mods_state.mods, m)
	}
	// Deterministic load order: ascending priority, then folder name.
	slice.sort_by(mods_state.mods[:], proc(a, b: Mod_Entry) -> bool {
		if a.priority != b.priority {
			return a.priority < b.priority
		}
		return a.folder < b.folder
	})

	if !config.mods_enabled {
		return
	}

	for &m, idx in mods_state.mods {
		if !m.enabled {
			continue
		}
		mods_state.active_mods += 1
		m.patch_count = load_mod_code_patches(idx, m.dir)
		if config.mods_textures {
			m.tex_count = load_mod_textures(m.dir)
			mods_state.loaded_tex += m.tex_count
		}
		m.disc_count = load_mod_disc_overrides(m.dir)
	}

	// Apply boot-time code patches immediately
	mods_apply_patches()
	if mods_state.active_mods > 0 {
		fmt.eprintfln(
			"mods: loaded %d active mod(s): %d code patch(es), %d texture(s), %d disc override(s)",
			mods_state.active_mods,
			len(mods_state.patches),
			mods_state.loaded_tex,
			len(mods_state.disc_files),
		)
	}
}

// Re-apply continuous and overlay-conditional code patches each vblank so
// dynamically loaded PS1 overlays are automatically patched on load.
@(private)
mods_vblank :: proc() {
	if !config.mods_enabled || len(mods_state.patches) == 0 {
		return
	}
	mods_apply_patches()
}

@(private)
mods_toggle :: proc(index: int) -> bool {
	if index < 0 || index >= len(mods_state.mods) {
		return false
	}
	m := &mods_state.mods[index]
	m.enabled = !m.enabled
	write_mod_enabled(m.dir, m.name, m.author, m.version, m.description, m.priority, m.enabled)
	mods_reload()
	return true
}

@(private = "file")
is_ignored_mod_dir :: proc(name: string) -> bool {
	if name == "" || strings.has_prefix(name, ".") || strings.has_prefix(name, "_") {
		return true
	}
	low := strings.to_lower(name, context.temp_allocator)
	return low == "dumped_textures" || low == "dumps"
}

@(private = "file")
read_mod_manifest :: proc(dir, folder: string, allocator := context.allocator) -> Mod_Entry {
	m := Mod_Entry {
		folder   = strings.clone(folder, allocator),
		dir      = strings.clone(dir, allocator),
		name     = strings.clone(folder, allocator),
		author   = strings.clone("Unknown", allocator),
		version  = strings.clone("1.0", allocator),
		enabled  = true,
		priority = 100,
	}
	ini_path, _ := filepath.join({dir, "mod.ini"}, context.temp_allocator)
	if !os.exists(ini_path) {
		return m
	}
	table, err, ok := ini.load_map_from_path(ini_path, context.temp_allocator)
	if err != nil || !ok {
		return m
	}
	for _, pairs in table {
		for k, v in pairs {
			switch strings.to_lower(k, context.temp_allocator) {
			case "name":
				if v != "" {
					delete(m.name, allocator)
					m.name = strings.clone(v, allocator)
				}
			case "author":
				if v != "" {
					delete(m.author, allocator)
					m.author = strings.clone(v, allocator)
				}
			case "version":
				if v != "" {
					delete(m.version, allocator)
					m.version = strings.clone(v, allocator)
				}
			case "description":
				delete(m.description, allocator)
				m.description = strings.clone(v, allocator)
			case "enabled":
				low := strings.to_lower(v, context.temp_allocator)
				m.enabled = low == "true" || low == "1" || low == "yes"
			case "priority":
				if p, pok := strconv.parse_int(v, 10); pok {
					m.priority = p
				}
			}
		}
	}
	return m
}

@(private = "file")
write_mod_enabled :: proc(dir, name, author, version, desc: string, priority: int, enabled: bool) {
	ini_path, _ := filepath.join({dir, "mod.ini"}, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "[mod]")
	fmt.sbprintfln(&b, "name = %s", name)
	fmt.sbprintfln(&b, "author = %s", author)
	fmt.sbprintfln(&b, "version = %s", version)
	if desc != "" {
		fmt.sbprintfln(&b, "description = %s", desc)
	}
	fmt.sbprintfln(&b, "priority = %d", priority)
	fmt.sbprintfln(&b, "enabled = %s", enabled ? "true" : "false")
	_ = os.write_entire_file(ini_path, transmute([]u8)strings.to_string(b))
}

// ---------------------------------------------------------------- Code Patches

@(private = "file")
load_mod_code_patches :: proc(mod_idx: int, mod_dir: string) -> int {
	count := 0
	main_code, _ := filepath.join({mod_dir, "code.txt"}, context.temp_allocator)
	if os.exists(main_code) {
		count += parse_patch_file(mod_idx, main_code)
	}
	patches_dir, _ := filepath.join({mod_dir, "patches"}, context.temp_allocator)
	if os.exists(patches_dir) {
		if entries, err := os.read_all_directory_by_path(patches_dir, context.temp_allocator); err == nil {
			for e in entries {
				if e.type == .Directory {
					continue
				}
				low := strings.to_lower(e.name, context.temp_allocator)
				if strings.has_suffix(low, ".txt") || strings.has_suffix(low, ".patch") || strings.has_suffix(low, ".cht") {
					count += parse_patch_file(mod_idx, e.fullpath)
				}
			}
		}
	}
	return count
}

@(private = "file")
parse_patch_file :: proc(mod_idx: int, path: string) -> int {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("mods: cannot read patch file", path, err)
		return 0
	}
	return parse_patch_text(mod_idx, string(data))
}

// Parse mod code patch syntax (exposed internally for unit testing).
@(private)
parse_patch_text :: proc(mod_idx: int, text: string) -> int {
	added := 0
	pending_cond: Mod_Cond_Kind = .None
	pending_caddr: u32
	pending_cval: u32

	for raw_line in strings.split_lines(text, context.temp_allocator) {
		line := strip_patch_comment(raw_line)
		if line == "" {
			continue
		}
		// Check conditional arrow syntax:
		//   if32 0x80012340 == 0x24020001 -> write32 0x80012340 0x24020063
		//   if16 0x80012340 != 0x0000     -> write16 0x80012340 0x03E7
		if arrow := strings.index(line, "->"); arrow >= 0 {
			lhs := strings.trim_space(line[:arrow])
			rhs := strings.trim_space(line[arrow + 2:])
			cond, ca, cv, cok := parse_condition(lhs)
			if !cok {
				continue
			}
			if p, pok := parse_action(mod_idx, rhs); pok {
				p.cond = cond
				p.cond_addr = ca
				p.cond_val = cv
				append(&mods_state.patches, p)
				added += 1
			}
			pending_cond = .None
			continue
		}

		// Standard PS1 GameShark / Action Replay 2-token hex lines:
		//   80XXXXXX YYYY (16-bit write)
		//   30XXXXXX 00YY (8-bit write)
		//   D0XXXXXX YYYY (if16 == guard for next line)
		//   D1XXXXXX YYYY (if16 != guard for next line)
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 2 && len(fields[0]) == 8 && is_hex_str(fields[0]) && is_hex_str(fields[1]) {
			code, ok1 := strconv.parse_u64(fields[0], 16)
			val, ok2 := strconv.parse_u64(fields[1], 16)
			if ok1 && ok2 {
				prefix := u8(code >> 24)
				addr := u32(0x80000000 | (code & 0x001fffff))
				switch prefix {
				case 0xD0:
					pending_cond, pending_caddr, pending_cval = .Eq16, addr, u32(val & 0xffff)
					continue
				case 0xD1:
					pending_cond, pending_caddr, pending_cval = .Ne16, addr, u32(val & 0xffff)
					continue
				case 0x80:
					p := Mod_Code_Patch {
						mod_idx   = mod_idx,
						kind      = .Write16,
						cond      = pending_cond,
						cond_addr = pending_caddr,
						cond_val  = pending_cval,
						addr      = addr,
						val       = u32(val & 0xffff),
					}
					append(&mods_state.patches, p)
					added += 1
					pending_cond = .None
					continue
				case 0x30:
					p := Mod_Code_Patch {
						mod_idx   = mod_idx,
						kind      = .Write8,
						cond      = pending_cond,
						cond_addr = pending_caddr,
						cond_val  = pending_cval,
						addr      = addr,
						val       = u32(val & 0xff),
					}
					append(&mods_state.patches, p)
					added += 1
					pending_cond = .None
					continue
				}
			}
		}

		// Plain action line: [once] write8|write16|write32|nop|bytes ...
		if p, pok := parse_action(mod_idx, line); pok {
			if pending_cond != .None {
				p.cond = pending_cond
				p.cond_addr = pending_caddr
				p.cond_val = pending_cval
				pending_cond = .None
			}
			append(&mods_state.patches, p)
			added += 1
		}
	}
	return added
}

@(private = "file")
strip_patch_comment :: proc(s: string) -> string {
	out := s
	for marker in ([3]string{"//", "#", ";"}) {
		if i := strings.index(out, marker); i >= 0 {
			out = out[:i]
		}
	}
	return strings.trim_space(out)
}

@(private = "file")
is_hex_str :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for ch in s {
		ok := (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')
		if !ok {
			return false
		}
	}
	return true
}

@(private = "file")
parse_u32_num :: proc(s: string) -> (u32, bool) {
	t := strings.trim_space(s)
	if strings.has_prefix(t, "0x") || strings.has_prefix(t, "0X") {
		v, ok := strconv.parse_u64(t[2:], 16)
		return u32(v), ok
	}
	if is_hex_str(t) && len(t) == 8 {
		v, ok := strconv.parse_u64(t, 16)
		return u32(v), ok
	}
	v, ok := strconv.parse_u64(t, 0)
	return u32(v), ok
}

@(private = "file")
parse_condition :: proc(lhs: string) -> (kind: Mod_Cond_Kind, addr, val: u32, ok: bool) {
	parts := strings.fields(lhs, context.temp_allocator)
	if len(parts) != 4 {
		return
	}
	kw := strings.to_lower(parts[0], context.temp_allocator)
	a, aok := parse_u32_num(parts[1])
	op := parts[2]
	v, vok := parse_u32_num(parts[3])
	if !aok || !vok {
		return
	}
	switch kw {
	case "if32":
		if op == "==" {
			return .Eq32, a, v, true
		} else if op == "!=" {
			return .Ne32, a, v, true
		}
	case "if16":
		if op == "==" {
			return .Eq16, a, v & 0xffff, true
		} else if op == "!=" {
			return .Ne16, a, v & 0xffff, true
		}
	}
	return
}

@(private = "file")
parse_action :: proc(mod_idx: int, rhs: string) -> (p: Mod_Code_Patch, ok: bool) {
	parts := strings.fields(rhs, context.temp_allocator)
	if len(parts) < 2 {
		return
	}
	p.mod_idx = mod_idx
	i := 0
	if strings.to_lower(parts[0], context.temp_allocator) == "once" {
		p.once = true
		i = 1
		if len(parts) < 3 {
			return
		}
	}
	kw := strings.to_lower(parts[i], context.temp_allocator)
	addr, aok := parse_u32_num(parts[i + 1])
	if !aok {
		return
	}
	p.addr = addr
	switch kw {
	case "nop":
		p.kind = .Write32
		p.val = 0x00000000
		return p, true
	case "write8":
		if len(parts) < i + 3 {
			return
		}
		v, vok := parse_u32_num(parts[i + 2])
		if !vok {
			return
		}
		p.kind = .Write8
		p.val = v & 0xff
		return p, true
	case "write16":
		if len(parts) < i + 3 {
			return
		}
		v, vok := parse_u32_num(parts[i + 2])
		if !vok {
			return
		}
		p.kind = .Write16
		p.val = v & 0xffff
		return p, true
	case "write32":
		if len(parts) < i + 3 {
			return
		}
		v, vok := parse_u32_num(parts[i + 2])
		if !vok {
			return
		}
		p.kind = .Write32
		p.val = v
		return p, true
	case "bytes":
		if len(parts) < i + 3 {
			return
		}
		buf := make([dynamic]u8, 0, len(parts) - (i + 2))
		for tok in parts[i + 2:] {
			clean := strings.trim_prefix(strings.trim_prefix(tok, "0x"), "0X")
			bv, bok := strconv.parse_u64(clean, 16)
			if !bok || bv > 0xff {
				delete(buf)
				return {}, false
			}
			append(&buf, u8(bv))
		}
		p.kind = .Bytes
		p.bytes = buf[:]
		return p, true
	}
	return
}

@(private)
mods_apply_patches :: proc() {
	for &p in mods_state.patches {
		if p.once && p.applied {
			continue
		}
		if !valid_ps1_ram(p.addr) {
			continue
		}
		switch p.cond {
		case .None:
		case .Eq16:
			if !valid_ps1_ram(p.cond_addr) || u32(cpu.r16(p.cond_addr)) != p.cond_val {
				continue
			}
		case .Ne16:
			if !valid_ps1_ram(p.cond_addr) || u32(cpu.r16(p.cond_addr)) == p.cond_val {
				continue
			}
		case .Eq32:
			if !valid_ps1_ram(p.cond_addr) || cpu.r32(p.cond_addr) != p.cond_val {
				continue
			}
		case .Ne32:
			if !valid_ps1_ram(p.cond_addr) || cpu.r32(p.cond_addr) == p.cond_val {
				continue
			}
		}

		// Write through cpu.w8/w16/w32 so cpu.ram_touch automatically demotes
		// any recompiled code page and modified MIPS code runs cleanly!
		switch p.kind {
		case .Write8:
			if cpu.r8(p.addr) != u8(p.val) {
				cpu.w8(p.addr, u8(p.val))
			}
		case .Write16:
			if u32(cpu.r16(p.addr)) != p.val {
				cpu.w16(p.addr, u16(p.val))
			}
		case .Write32:
			if cpu.r32(p.addr) != p.val {
				cpu.w32(p.addr, p.val)
			}
		case .Bytes:
			for b, k in p.bytes {
				a := p.addr + u32(k)
				if valid_ps1_ram(a) && cpu.r8(a) != b {
					cpu.w8(a, b)
				}
			}
		}
		p.applied = true
	}
}

@(private = "file")
valid_ps1_ram :: #force_inline proc(addr: u32) -> bool {
	return (addr & 0x1fffffff) < cpu.RAM_SIZE
}

// ---------------------------------------------------------------- Texture Packs

@(private = "file")
load_mod_textures :: proc(mod_dir: string) -> int {
	when !PS_ANDROID_PATCH {
		return 0
	} else {
		tex_dir, _ := filepath.join({mod_dir, "textures"}, context.temp_allocator)
		if !os.exists(tex_dir) {
			return 0
		}
		return load_textures_recursive(tex_dir)
	}
}

@(private = "file")
load_textures_recursive :: proc(dir: string) -> int {
	when !PS_ANDROID_PATCH {
		return 0
	} else {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			return 0
		}
		count := 0
		for e in entries {
			if e.type == .Directory {
				count += load_textures_recursive(e.fullpath)
				continue
			}
			low := strings.to_lower(e.name, context.temp_allocator)
			if !strings.has_suffix(low, ".png") {
				continue
			}
			if load_single_mod_png(e.fullpath, e.name) {
				count += 1
			}
		}
		return count
	}
}

@(private = "file")
load_single_mod_png :: proc(path, filename: string) -> bool {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(raw) == 0 {
		return false
	}
	img, perr := png.load_from_bytes(raw, {.alpha_add_if_missing}, context.temp_allocator)
	if perr != nil || img == nil {
		fmt.eprintln("mods: invalid PNG texture:", path, perr)
		return false
	}
	defer image.destroy(img, context.temp_allocator)
	if img.width <= 0 || img.height <= 0 || img.width > 2048 || img.height > 2048 {
		return false
	}
	px := image_to_argb32(img, context.temp_allocator)
	if len(px) == 0 {
		return false
	}

	stem := filename[:len(filename) - 4] // strip ".png"
	low := strings.to_lower(stem, context.temp_allocator)

	// Pattern 1: vram_<x>_<y>_<w>x<h>.png (direct 15-bit PS1 VRAM replacement)
	if strings.has_prefix(low, "vram_") {
		if vx, vy, vw, vh, ok := parse_vram_tex_name(low[5:]); ok {
			when PS_ANDROID_PATCH {
				render.mod_tex_register_vram(vx, vy, vw, vh, px, i32(img.width), i32(img.height))
				return true
			} else {
				_ = vx; _ = vy; _ = vw; _ = vh
				return false
			}
		}
	}

	// Pattern 2: <16hex_hash>.png OR <16hex_hash>_anything.png (from Dump Textures!)
	if len(stem) >= 16 && is_hex_str(stem[:16]) && (len(stem) == 16 || stem[16] == '_') {
		if h, hok := strconv.parse_u64(stem[:16], 16); hok {
			when PS_ANDROID_PATCH {
				render.mod_tex_register_hash(h, px, i32(img.width), i32(img.height))
				return true
			} else {
				_ = h
				return false
			}
		}
	}

	// Pattern 3: <tex_x>_<tex_y>_<clut_x>_<clut_y>_<u>_<v>_<w>x<h>.png
	if tx, ty, cx, cy, u0, v0, w, h, ok := parse_coord_tex_name(low); ok {
		when PS_ANDROID_PATCH {
			render.mod_tex_register_coord(tx, ty, cx, cy, u0, v0, w, h, px, i32(img.width), i32(img.height))
			return true
		} else {
			_ = tx; _ = ty; _ = cx; _ = cy; _ = u0; _ = v0; _ = w; _ = h
			return false
		}
	}

	fmt.eprintln("mods: skipped texture with unrecognized naming pattern:", filename)
	return false
}

@(private = "file")
image_to_argb32 :: proc(img: ^image.Image, allocator := context.temp_allocator) -> []u32 {
	n := img.width * img.height
	out := make([]u32, n, allocator)
	src := img.pixels[:]
	ch := img.channels
	if ch == 4 && len(src) >= n * 4 {
		for i in 0 ..< n {
			o := i * 4
			out[i] = u32(src[o + 3]) << 24 | u32(src[o]) << 16 | u32(src[o + 1]) << 8 | u32(src[o + 2])
		}
	} else if ch == 3 && len(src) >= n * 3 {
		for i in 0 ..< n {
			o := i * 3
			out[i] = 0xff000000 | u32(src[o]) << 16 | u32(src[o + 1]) << 8 | u32(src[o + 2])
		}
	} else if ch == 2 && len(src) >= n * 2 {
		for i in 0 ..< n {
			o := i * 2
			g := u32(src[o])
			out[i] = u32(src[o + 1]) << 24 | g << 16 | g << 8 | g
		}
	} else if ch == 1 && len(src) >= n {
		for i in 0 ..< n {
			g := u32(src[i])
			out[i] = 0xff000000 | g << 16 | g << 8 | g
		}
	} else {
		return nil
	}
	return out
}

@(private)
parse_vram_tex_name :: proc(s: string) -> (x, y, w, h: i32, ok: bool) {
	parts := strings.split(s, "_", context.temp_allocator)
	if len(parts) != 3 {
		return
	}
	xi, xok := strconv.parse_int(parts[0], 10)
	yi, yok := strconv.parse_int(parts[1], 10)
	wh := strings.split(parts[2], "x", context.temp_allocator)
	if !xok || !yok || len(wh) != 2 {
		return
	}
	wi, wok := strconv.parse_int(wh[0], 10)
	hi, hok := strconv.parse_int(wh[1], 10)
	if !wok || !hok || wi <= 0 || hi <= 0 {
		return
	}
	return i32(xi), i32(yi), i32(wi), i32(hi), true
}

@(private)
parse_coord_tex_name :: proc(s: string) -> (tx, ty, cx, cy, u0, v0, w, h: i32, ok: bool) {
	parts := strings.split(s, "_", context.temp_allocator)
	if len(parts) != 7 {
		return
	}
	vals: [6]i32
	for i in 0 ..< 6 {
		v, vok := strconv.parse_int(parts[i], 10)
		if !vok {
			return
		}
		vals[i] = i32(v)
	}
	wh := strings.split(parts[6], "x", context.temp_allocator)
	if len(wh) != 2 {
		return
	}
	wi, wok := strconv.parse_int(wh[0], 10)
	hi, hok := strconv.parse_int(wh[1], 10)
	if !wok || !hok || wi <= 0 || hi <= 0 {
		return
	}
	return vals[0], vals[1], vals[2], vals[3], vals[4], vals[5], i32(wi), i32(hi), true
}

// ---------------------------------------------------------------- Disc Overrides

@(private = "file")
load_mod_disc_overrides :: proc(mod_dir: string) -> int {
	disc_root, _ := filepath.join({mod_dir, "disc"}, context.temp_allocator)
	if !os.exists(disc_root) {
		return 0
	}
	d := spu.disc_image()
	if d == nil {
		return 0
	}
	return load_disc_recursive(d, disc_root, "")
}

@(private = "file")
load_disc_recursive :: proc(d: ^disc.Disc, fs_dir, iso_prefix: string) -> int {
	entries, err := os.read_all_directory_by_path(fs_dir, context.temp_allocator)
	if err != nil {
		return 0
	}
	count := 0
	for e in entries {
		iso_path := iso_prefix == "" ? e.name : fmt.tprintf("%s/%s", iso_prefix, e.name)
		if e.type == .Directory {
			count += load_disc_recursive(d, e.fullpath, iso_path)
			continue
		}
		iso_upper := strings.to_upper(iso_path, context.temp_allocator)
		de, found := disc.find(d, iso_upper, context.temp_allocator)
		if !found || de.dir {
			fmt.eprintln("mods: disc override not found in ISO9660:", iso_upper)
			continue
		}
		raw, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil {
			continue
		}
		orig_sectors := (de.size + spu.DISC_DATA - 1) / spu.DISC_DATA
		padded := make([]u8, int(orig_sectors * spu.DISC_DATA))
		copy(padded, raw[:min(len(raw), len(padded))])
		append(
			&mods_state.disc_files,
			Mod_Disc_Override {
				lba_start = de.lba,
				lba_end   = de.lba + orig_sectors,
				data      = padded,
				iso_path  = strings.clone(iso_upper),
			},
		)
		count += 1
	}
	return count
}

@(private = "file")
mods_sector_hook :: proc(lba: u32) -> []u8 {
	if config.mods_enabled {
		// Highest-priority mod (last appended) wins on overlapping disc files.
		for i := len(mods_state.disc_files) - 1; i >= 0; i -= 1 {
			df := &mods_state.disc_files[i]
			if lba >= df.lba_start && lba < df.lba_end {
				off := int(lba - df.lba_start) * spu.DISC_DATA
				return df.data[off:off + spu.DISC_DATA]
			}
		}
	}
	if mods_state.prev_sector != nil {
		return mods_state.prev_sector(lba)
	}
	return nil
}

// Helper for UI toast notifications.
@(private)
mods_reload_with_toast :: proc() {
	mods_reload()
	host.osd_toast(
		fmt.tprintf(
			"Mods: %d active, %d patches, %d textures",
			mods_state.active_mods,
			len(mods_state.patches),
			mods_state.loaded_tex,
		),
	)
}

@(private)
mods_request_android_setup :: proc() {
	_ = os.write_entire_file("bof4_open_setup.flag", transmute([]u8)string("1"))
}
