// Breath of Fire IV (SLUS-01324), statically recompiled from MIPS to Odin.
//
// The executable's code runs as recompiled procedures (package rec) on top of
// an emulated PS1 (package psx): RAM, BIOS HLE, GPU, CD-ROM, pad, timers.
package main

import "core:fmt"
import "core:os"

import "ps:core"
import psx "ps:psx"
import "qol"
import "rec"

run_bof4 :: proc(disc_dir, cue: string) -> bool {
	exe: []u8
	if disc_dir != "" {
		exe_path := fmt.tprintf("%s/SLUS_013.24", disc_dir)
		if os.exists(exe_path) {
			data, err := os.read_entire_file(exe_path, context.allocator)
			if err != nil {
				fmt.eprintln("cannot read", exe_path, err)
				return false
			}
			exe = data
		}
	}
	if exe == nil && !os.exists(cue) {
		fmt.eprintln("cannot find disc image:", cue)
		return false
	}
	native_path := core.env("NATIVE_FILE")
	if native_path == "" {
		when ODIN_ARCH == .arm64 {
			if os.exists("bof4_arm64.native") {
				native_path = "bof4_arm64.native"
			} else if os.exists("bof4.native") {
				native_path = "bof4.native"
			}
		} else {
			if os.exists("bof4.native") {
				native_path = "bof4.native"
			}
		}
	}
	ok := psx.run(
		{
			exe = exe,
			disc = cue,
			title = "Breath of Fire IV",
			funcs = rec.EXE_FUNCS[:],
			overlays = rec.register_overlays,
			// Machine code built from the same recompile (its native_arch and
			// native_out options) in place of the Odin functions; on failure
			// the Odin ones stay.
			native = native_path,
			cards = {"bof4_slot1.mcd", "bof4_slot2.mcd"},
			setup = qol.boot,
			hooks = qol.init,
		},
	)
	if !ok {
		return false
	}
	fmt.eprintln("game returned from its entry point")
	return true
}

main :: proc() {
	disc_dir := len(os.args) > 1 ? os.args[1] : "../disc"
	cue := len(os.args) > 2 ? os.args[2] : "../Breath of Fire IV.cue"
	if !run_bof4(disc_dir, cue) {
		os.exit(1)
	}
}
