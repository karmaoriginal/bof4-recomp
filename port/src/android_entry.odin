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

// Find the user's PS1 disc image (.cue preferred, then .iso/.bin) inside dir.
@(private = "file")
android_find_disc :: proc(dir: string) -> (disc_dir, cue_path: string) {
	// Optional extracted disc/SLUS_013.24 folder
	sub_disc := filepath.join({dir, "disc"}, context.temp_allocator)
	if os.exists(filepath.join({sub_disc, "SLUS_013.24"}, context.temp_allocator)) {
		disc_dir = sub_disc
	} else if os.exists(filepath.join({dir, "SLUS_013.24"}, context.temp_allocator)) {
		disc_dir = dir
	}

	// Exact canonical filename first
	canonical := filepath.join({dir, "Breath of Fire IV.cue"}, context.temp_allocator)
	if os.exists(canonical) {
		return disc_dir, canonical
	}

	// Fallback: scan directory for any .cue, then .iso, then .bin
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return disc_dir, canonical
	}
	best_bin := ""
	best_iso := ""
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
		if best_bin == "" && strings.has_suffix(low, ".bin") {
			best_bin = e.fullpath
		}
	}
	if best_iso != "" {
		return disc_dir, best_iso
	}
	if best_bin != "" {
		return disc_dir, best_bin
	}
	return disc_dir, canonical
}

// Exported C entry point invoked by org.libsdl.app.SDLActivity on Android.
@(export, link_name = "SDL_main")
android_sdl_main :: proc "c" (argc: c.int, argv: [^]cstring) -> c.int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	data_dir := android_data_dir(argc, argv)
	if data_dir != "" {
		if err := os.chdir(data_dir); err != nil {
			fmt.eprintln("android: chdir failed:", data_dir, err)
		}
	}

	disc_dir, cue := android_find_disc(data_dir)
	if argc > 2 && argv != nil && argv[2] != nil {
		if arg_cue := string(argv[2]); arg_cue != "" && os.exists(arg_cue) {
			cue = arg_cue
		}
	}

	if !os.exists(cue) {
		msg := fmt.ctprintf("Breath of Fire IV disc image not found in:\n%s", data_dir)
		sdl.AndroidShowToast(msg, 1, -1, 0, 0)
		fmt.eprintln(msg)
		return 1
	}

	if !run_bof4(disc_dir, cue) {
		sdl.AndroidShowToast("Breath of Fire IV failed to start. Check logcat for details.", 1, -1, 0, 0)
		return 1
	}
	return 0
}
