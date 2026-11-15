// Android SDL2 native entry point for Breath of Fire IV.
//
// Compiled when building libbof4.so with:
//   odin build src -target:linux_arm64 -subtarget:android -minimum-os-version:29 -build-mode:shared ...
//
// SDLActivity loads libSDL2.so and libbof4.so, runs Odin's .init runtime setup,
// and then invokes SDL_main(argc, argv) on the SDL thread.
#+build linux:android
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import sdl "vendor:sdl2"

// Locate the app's persistent data directory where saves (bof4_slot*.mcd),
// bof4.ini, and the user's Breath of Fire IV disc image live.
@(private = "file")
android_data_dir :: proc(argc: c.int, argv: [^]cstring) -> string {
	if env_dir := os.get_env("BOF4_DATA_DIR", context.temp_allocator); env_dir != "" {
		return env_dir
	}
	if argc > 1 && argv != nil && argv[1] != nil {
		if s := string(argv[1]); s != "" && os.exists(s) {
			return s
		}
	}
	if ext := sdl.AndroidGetExternalStoragePath(); ext != nil {
		if s := string(ext); s != "" {
			return s
		}
	}
	if internal := sdl.AndroidGetInternalStoragePath(); internal != nil {
		if s := string(internal); s != "" {
			return s
		}
	}
	return "."
}

// Check whether a single .bin/.iso file has an ISO9660 "CD001" volume header
// at sector 16 (2048-byte ISO or 2352-byte Mode 2 Form 1 raw BIN).
@(private = "file")
file_has_iso9660 :: proc(path: string) -> bool {
	f, err := os.open(path)
	if err != nil {
		return false
	}
	defer os.close(f)
	magic: [5]u8
	// Raw 2352-byte sector 16: 16 * 2352 + 24 (header) + 1 = 37657
	if n, rerr := os.read_at(f, magic[:], 16 * 2352 + 24 + 1); rerr == nil && n == 5 && string(magic[:]) == "CD001" {
		return true
	}
	// Mode 1 2352-byte sector 16: 16 * 2352 + 16 + 1 = 37649
	if n, rerr := os.read_at(f, magic[:], 16 * 2352 + 16 + 1); rerr == nil && n == 5 && string(magic[:]) == "CD001" {
		return true
	}
	// ISO 2048-byte sector 16: 16 * 2048 + 1 = 32769
	if n, rerr := os.read_at(f, magic[:], 16 * 2048 + 1); rerr == nil && n == 5 && string(magic[:]) == "CD001" {
		return true
	}
	return false
}

// Find the user's PS1 disc image (.cue preferred, then .iso/.bin with ISO9660) inside dir.
@(private = "file")
android_find_disc :: proc(dir: string) -> (disc_dir, cue_path: string) {
	// Optional extracted disc/SLUS_013.24 folder
	sub_disc, _ := filepath.join({dir, "disc"}, context.temp_allocator)
	sub_exe, _ := filepath.join({sub_disc, "SLUS_013.24"}, context.temp_allocator)
	dir_exe, _ := filepath.join({dir, "SLUS_013.24"}, context.temp_allocator)
	if os.exists(sub_exe) {
		disc_dir = sub_disc
	} else if os.exists(dir_exe) {
		disc_dir = dir
	}

	// Exact canonical filename first
	canonical, _ := filepath.join({dir, "Breath of Fire IV.cue"}, context.temp_allocator)
	if os.exists(canonical) {
		return disc_dir, canonical
	}

	// Fallback: scan directory for any .cue, then .iso, then valid ISO9660 .bin
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return disc_dir, canonical
	}
	best_iso := ""
	best_data_bin := ""
	best_any_bin := ""
	for e in entries {
		if e.type == .Directory {
			continue
		}
		low := strings.to_lower(e.name, context.temp_allocator)
		if strings.has_suffix(low, ".cue") {
			return disc_dir, e.fullpath
		}
		if best_iso == "" && strings.has_suffix(low, ".iso") {
			best_iso = e.fullpath
		}
		if strings.has_suffix(low, ".bin") || strings.has_suffix(low, ".img") {
			if best_any_bin == "" {
				best_any_bin = e.fullpath
			}
			if best_data_bin == "" && file_has_iso9660(e.fullpath) {
				best_data_bin = e.fullpath
			}
		}
	}
	if best_iso != "" {
		return disc_dir, best_iso
	}
	if best_data_bin != "" {
		return disc_dir, best_data_bin
	}
	if best_any_bin != "" {
		return disc_dir, best_any_bin
	}
	return disc_dir, canonical
}

@(private = "file")
write_last_error :: proc(summary: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, summary)
	if log_bytes, err := os.read_entire_file("bof4_boot.log", context.temp_allocator); err == nil && len(log_bytes) > 0 {
		fmt.sbprintln(&b, "")
		fmt.sbprintln(&b, "--- Boot log ---")
		strings.write_bytes(&b, log_bytes)
	}
	_ = os.write_entire_file("bof4_last_error.txt", transmute([]u8)strings.to_string(b))
}

// Exported C entry point invoked by org.libsdl.app.SDLActivity on Android.
@(export, link_name = "SDL_main")
android_sdl_main :: proc "c" (argc: c.int, argv: [^]cstring) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	data_dir := android_data_dir(argc, argv)
	if data_dir != "" {
		_ = os.chdir(data_dir)
	}

	// Capture stderr to bof4_boot.log so any startup failure is shown in-app.
	log_file, log_err := os.create("bof4_boot.log")
	if log_err == nil && log_file != nil {
		_ = posix.dup2(posix.FD(os.fd(log_file)), posix.FD(os.fd(os.stderr)))
	}
	defer if log_file != nil {
		os.close(log_file)
	}

	if os.exists("bof4_last_error.txt") {
		_ = os.remove("bof4_last_error.txt")
	}

	fmt.eprintln("android: data_dir =", data_dir)
	if entries, derr := os.read_all_directory_by_path(".", context.temp_allocator); derr == nil {
		for e in entries {
			if e.type != .Directory {
				fmt.eprintfln("android: file: %s (%d bytes)", e.name, e.size)
			}
		}
	}

	disc_dir, cue := android_find_disc(data_dir)
	if argc > 2 && argv != nil && argv[2] != nil {
		if arg_cue := string(argv[2]); arg_cue != "" && os.exists(arg_cue) {
			cue = arg_cue
		}
	}
	fmt.eprintln("android: selected disc =", cue, "disc_dir =", disc_dir)

	if !os.exists(cue) {
		msg := fmt.tprintf("No se encontró la imagen del disco en: %s", data_dir)
		fmt.eprintln("android:", msg)
		write_last_error(msg)
		sdl.AndroidShowToast(fmt.ctprintf("%s", msg), 1, -1, 0, 0)
		return 1
	}

	fmt.eprintln("android: calling run_bof4...")
	if !run_bof4(disc_dir, cue) {
		fmt.eprintln("android: run_bof4 returned false")
		write_last_error("El juego no pudo iniciar con los archivos seleccionados.")
		sdl.AndroidShowToast("Error al iniciar Breath of Fire IV. Revisa el registro en pantalla.", 1, -1, 0, 0)
		return 1
	}

	if os.exists("bof4_launching.flag") {
		_ = os.remove("bof4_launching.flag")
	}
	return 0
}
