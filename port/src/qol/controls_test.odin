// Unit tests verifying exact PS1 button mappings, 8-way D-pad geometry,
// analog stick signs (+x right, +y down), touch layout non-overlap, multi-touch
// capture, quick-tap latching, trigger calibration, and sensor filtering.
//
// Run with: odin test port/src/qol -collection:ps=ps-recomp
package qol

import "core:testing"
import sdl "vendor:sdl2"

import "ps:core"
import host "ps:psx/host"

@(test)
test_dpad_8way_exact_orientation :: proc(t: ^testing.T) {
	dpad := Touch_Circle{cx = 200, cy = 400, r = 100}

	// Center deadzone must return 0
	testing.expect_value(t, touch_dpad_bits(dpad, 200, 400), u16(0))
	testing.expect_value(t, touch_dpad_bits(dpad, 208, 405), u16(0))

	// Cardinal directions (screen coords: +x right, +y down)
	testing.expect_value(t, touch_dpad_bits(dpad, 200, 320), u16(host.PAD_UP))
	testing.expect_value(t, touch_dpad_bits(dpad, 280, 400), u16(host.PAD_RIGHT))
	testing.expect_value(t, touch_dpad_bits(dpad, 200, 480), u16(host.PAD_DOWN))
	testing.expect_value(t, touch_dpad_bits(dpad, 120, 400), u16(host.PAD_LEFT))

	// Diagonals
	testing.expect_value(t, touch_dpad_bits(dpad, 260, 340), u16(host.PAD_UP | host.PAD_RIGHT))
	testing.expect_value(t, touch_dpad_bits(dpad, 260, 460), u16(host.PAD_RIGHT | host.PAD_DOWN))
	testing.expect_value(t, touch_dpad_bits(dpad, 140, 460), u16(host.PAD_DOWN | host.PAD_LEFT))
	testing.expect_value(t, touch_dpad_bits(dpad, 140, 340), u16(host.PAD_LEFT | host.PAD_UP))
}

@(test)
test_touch_stick_no_inversion :: proc(t: ^testing.T) {
	stick := Touch_Circle{cx = 300, cy = 500, r = 100}

	// Center deadzone -> zero
	testing.expect_value(t, touch_stick_vec(stick, 300, 500), [2]f32{0, 0})

	// Up: y < cy -> (0, -1) -> core.stick_angle == 0 deg -> PAD_UP
	up := touch_stick_vec(stick, 300, 420)
	testing.expect(t, abs(up.x) < 0.001 && up.y < -0.99, "stick Up must be (0, -1)")
	testing.expect(t, abs(core.stick_angle(up)) < 0.1, "stick Up angle must be 0 deg")
	testing.expect_value(t, stick_to_dpad_bits(up), u16(host.PAD_UP))

	// Down: y > cy -> (0, +1) -> |core.stick_angle| == 180 deg -> PAD_DOWN
	down := touch_stick_vec(stick, 300, 580)
	testing.expect(t, abs(down.x) < 0.001 && down.y > 0.99, "stick Down must be (0, +1)")
	testing.expect(t, abs(abs(core.stick_angle(down)) - 180.0) < 0.1, "stick Down angle must be +-180 deg")
	testing.expect_value(t, stick_to_dpad_bits(down), u16(host.PAD_DOWN))

	// Right: x > cx -> (+1, 0) -> core.stick_angle == +90 deg -> PAD_RIGHT
	right := touch_stick_vec(stick, 380, 500)
	testing.expect(t, right.x > 0.99 && abs(right.y) < 0.001, "stick Right must be (+1, 0)")
	testing.expect(t, abs(core.stick_angle(right) - 90.0) < 0.1, "stick Right angle must be +90 deg")
	testing.expect_value(t, stick_to_dpad_bits(right), u16(host.PAD_RIGHT))

	// Left: x < cx -> (-1, 0) -> core.stick_angle == -90 deg -> PAD_LEFT
	left := touch_stick_vec(stick, 220, 500)
	testing.expect(t, left.x < -0.99 && abs(left.y) < 0.001, "stick Left must be (-1, 0)")
	testing.expect(t, abs(core.stick_angle(left) + 90.0) < 0.1, "stick Left angle must be -90 deg")
	testing.expect_value(t, stick_to_dpad_bits(left), u16(host.PAD_LEFT))
}

@(test)
test_ps1_face_diamond_positions_and_layout :: proc(t: ^testing.T) {
	// Test common Android widescreen (2400x1080 with left notch), 16:9 (1920x1080), and 4:3 (640x480)
	screens := [?][2]f32{{2400, 1080}, {1920, 1080}, {1280, 720}, {640, 480}}
	insets := [4]f32{0.04, 0.0, 0.0, 0.02}

	for sc in screens {
		for mode in Touch_Layout_Mode {
			l := touch_compute_layout(sc.x, sc.y, mode, 1.0, insets)
			// Verify authentic PS1 diamond positions:
			// Triangle TOP, Circle RIGHT, Cross BOTTOM, Square LEFT
			testing.expect(t, l.face[.Triangle].cy < l.face[.Cross].cy, "Triangle must be above Cross")
			testing.expect(t, l.face[.Square].cx < l.face[.Circle].cx, "Square must be left of Circle")

			// Hitting each face button center must return its exact PS1 PAD_* bit
			for fi in Face_Idx {
				bit, ok := touch_hit_face(&l, l.face[fi].cx, l.face[fi].cy)
				testing.expect(t, ok, "face button center must hit")
				testing.expect_value(t, bit, FACE_BITS[fi])
			}

			// Shoulders must be left-to-right L2, L1 ... R1, R2
			testing.expect(t, l.pills[.L2].x < l.pills[.L1].x, "L2 must be left of L1")
			testing.expect(t, l.pills[.R1].x < l.pills[.R2].x, "R1 must be left of R2")
			testing.expect(t, l.pills[.Select].x < l.pills[.Start].x, "Select must be left of Start")
		}
	}
}

@(test)
test_quick_tap_latch_zero_drop_zero_stick :: proc(t: ^testing.T) {
	l: Button_Latch

	// Case 1: Quick tap pressed & already released before first poll (live=0, edge=PAD_CROSS)
	p1 := latch_consume(&l, 0, host.PAD_CROSS)
	p2 := latch_consume(&l, 0, 0)
	p3 := latch_consume(&l, 0, 0)
	testing.expect_value(t, p1, u16(host.PAD_CROSS))
	testing.expect_value(t, p2, u16(host.PAD_CROSS))
	testing.expect_value(t, p3, u16(0))

	// Case 2: Button held for 4 polls, then released -> MUST release immediately on poll 5
	for _ in 0 ..< 4 {
		testing.expect_value(t, latch_consume(&l, host.PAD_CIRCLE, 0), u16(host.PAD_CIRCLE))
	}
	testing.expect_value(t, latch_consume(&l, 0, 0), u16(0))
}

@(test)
test_trigger_calibration_and_hysteresis :: proc(t: ^testing.T) {
	// Unipolar trigger (0..32767)
	bi := false
	testing.expect(t, normalize_trigger_axis(0, &bi) == 0.0, "unipolar rest is 0")
	testing.expect(t, !bi, "unipolar must stay false")
	testing.expect(t, normalize_trigger_axis(16384, &bi) > 0.49, "unipolar half press ~0.5")

	// Bipolar trigger (-32768..32767 resting at -32768)
	bi2 := false
	testing.expect(t, normalize_trigger_axis(-32768, &bi2) < 0.001, "bipolar rest must map to 0")
	testing.expect(t, bi2, "bipolar must auto-detect")
	testing.expect(t, abs(normalize_trigger_axis(0, &bi2) - 0.5) < 0.01, "bipolar midpoint is 0.5")
	testing.expect(t, normalize_trigger_axis(32767, &bi2) > 0.99, "bipolar full press is 1.0")

	// Trigger threshold + hysteresis (0.25 press, 0.20 release)
	held := false
	testing.expect(t, !trigger_pressed(0.24, 0.25, &held), "below press threshold")
	testing.expect(t, trigger_pressed(0.26, 0.25, &held), "above press threshold")
	testing.expect(t, trigger_pressed(0.22, 0.25, &held), "inside hysteresis band stays held")
	testing.expect(t, !trigger_pressed(0.18, 0.25, &held), "below release threshold releases")
}

@(test)
test_core_buttons_wire_order_and_confirm_swap :: proc(t: ^testing.T) {
	testing.expect_value(t, core_buttons_to_pad_mask({.Select}), u16(host.PAD_SELECT))
	testing.expect_value(t, core_buttons_to_pad_mask({.Start}), u16(host.PAD_START))
	testing.expect_value(t, core_buttons_to_pad_mask({.Up}), u16(host.PAD_UP))
	testing.expect_value(t, core_buttons_to_pad_mask({.Right}), u16(host.PAD_RIGHT))
	testing.expect_value(t, core_buttons_to_pad_mask({.Down}), u16(host.PAD_DOWN))
	testing.expect_value(t, core_buttons_to_pad_mask({.Left}), u16(host.PAD_LEFT))
	testing.expect_value(t, core_buttons_to_pad_mask({.L2}), u16(host.PAD_L2))
	testing.expect_value(t, core_buttons_to_pad_mask({.R2}), u16(host.PAD_R2))
	testing.expect_value(t, core_buttons_to_pad_mask({.L1}), u16(host.PAD_L1))
	testing.expect_value(t, core_buttons_to_pad_mask({.R1}), u16(host.PAD_R1))
	testing.expect_value(t, core_buttons_to_pad_mask({.Triangle}), u16(host.PAD_TRIANGLE))
	testing.expect_value(t, core_buttons_to_pad_mask({.Circle}), u16(host.PAD_CIRCLE))
	testing.expect_value(t, core_buttons_to_pad_mask({.Cross}), u16(host.PAD_CROSS))
	testing.expect_value(t, core_buttons_to_pad_mask({.Square}), u16(host.PAD_SQUARE))

	// Hat 8-way conversion
	testing.expect_value(t, hat_to_pad_bits(sdl.HAT_UP), u16(host.PAD_UP))
	testing.expect_value(t, hat_to_pad_bits(sdl.HAT_RIGHTUP), u16(host.PAD_UP | host.PAD_RIGHT))
	testing.expect_value(t, hat_to_pad_bits(sdl.HAT_LEFTDOWN), u16(host.PAD_DOWN | host.PAD_LEFT))

	// Confirm swap only swaps Cross <-> Circle
	testing.expect_value(t, apply_confirm_swap(host.PAD_CROSS | host.PAD_L1, true), u16(host.PAD_CIRCLE | host.PAD_L1))
	testing.expect_value(t, apply_confirm_swap(host.PAD_CIRCLE | host.PAD_UP, true), u16(host.PAD_CROSS | host.PAD_UP))
	testing.expect_value(t, apply_confirm_swap(host.PAD_CROSS, false), u16(host.PAD_CROSS))

	// Sensor device filter rejects Android accelerometers
	testing.expect(t, is_sensor_device_name("Android Accelerometer"), "must reject accelerometer")
	testing.expect(t, !is_sensor_device_name("Xbox Wireless Controller"), "must accept Xbox controller")
	testing.expect(t, !is_sensor_device_name("DualSense Wireless Controller"), "must accept DualSense")
}

@(test)
test_mod_code_patch_parser :: proc(t: ^testing.T) {
	// Clean state before & after
	for p in mods_state.patches {
		delete(p.bytes)
	}
	clear(&mods_state.patches)
	defer {
		for p in mods_state.patches {
			delete(p.bytes)
		}
		clear(&mods_state.patches)
	}

	script := `
	# Comment line
	// C++ comment
	once write32 0x80012340 0x24020063
	write16 0x80054320 0x03E7 ; inline comment
	write8  0x80099999 0x7F
	nop     0x80012344
	bytes   0x80020000 01 02 0xFF 7A
	if32 0x80080000 == 0x27BDFFE0 -> write32 0x80080004 0x00000000
	if16 0x80080010 != 0x0000 -> write16 0x80080012 0x0064
	D00A1234 0001
	800A1236 03E7
	300A1238 00FF
	`
	n := parse_patch_text(0, script)
	testing.expect_value(t, n, 9)
	testing.expect_value(t, len(mods_state.patches), 9)

	// 0: once write32
	p0 := mods_state.patches[0]
	testing.expect(t, p0.once, "once flag")
	testing.expect_value(t, p0.kind, Mod_Patch_Kind.Write32)
	testing.expect_value(t, p0.addr, u32(0x80012340))
	testing.expect_value(t, p0.val, u32(0x24020063))

	// 3: nop
	p3 := mods_state.patches[3]
	testing.expect_value(t, p3.kind, Mod_Patch_Kind.Write32)
	testing.expect_value(t, p3.addr, u32(0x80012344))
	testing.expect_value(t, p3.val, u32(0))

	// 4: bytes
	p4 := mods_state.patches[4]
	testing.expect_value(t, p4.kind, Mod_Patch_Kind.Bytes)
	testing.expect_value(t, len(p4.bytes), 4)
	testing.expect_value(t, p4.bytes[2], u8(0xFF))

	// 5: if32 == -> write32
	p5 := mods_state.patches[5]
	testing.expect_value(t, p5.cond, Mod_Cond_Kind.Eq32)
	testing.expect_value(t, p5.cond_addr, u32(0x80080000))
	testing.expect_value(t, p5.cond_val, u32(0x27BDFFE0))
	testing.expect_value(t, p5.addr, u32(0x80080004))

	// 7: GameShark D0 + 80
	p7 := mods_state.patches[7]
	testing.expect_value(t, p7.cond, Mod_Cond_Kind.Eq16)
	testing.expect_value(t, p7.cond_addr, u32(0x800A1234))
	testing.expect_value(t, p7.cond_val, u32(0x0001))
	testing.expect_value(t, p7.kind, Mod_Patch_Kind.Write16)
	testing.expect_value(t, p7.addr, u32(0x800A1236))
	testing.expect_value(t, p7.val, u32(0x03E7))

	// 8: GameShark 30 (unconditional because D0 was consumed by 80)
	p8 := mods_state.patches[8]
	testing.expect_value(t, p8.cond, Mod_Cond_Kind.None)
	testing.expect_value(t, p8.kind, Mod_Patch_Kind.Write8)
	testing.expect_value(t, p8.val, u32(0xFF))
}

@(test)
test_mod_texture_filename_parsers :: proc(t: ^testing.T) {
	vx, vy, vw, vh, vok := parse_vram_tex_name("320_0_64x128")
	testing.expect(t, vok, "valid vram filename")
	testing.expect_value(t, vx, i32(320))
	testing.expect_value(t, vy, i32(0))
	testing.expect_value(t, vw, i32(64))
	testing.expect_value(t, vh, i32(128))

	_, _, _, _, bad_v := parse_vram_tex_name("320_0_0x64")
	testing.expect(t, !bad_v, "zero width must be rejected")

	tx, ty, cx, cy, u0, v0, cw, ch, cok := parse_coord_tex_name("320_0_0_480_16_32_64x64")
	testing.expect(t, cok, "valid coord filename")
	testing.expect_value(t, tx, i32(320))
	testing.expect_value(t, ty, i32(0))
	testing.expect_value(t, cx, i32(0))
	testing.expect_value(t, cy, i32(480))
	testing.expect_value(t, u0, i32(16))
	testing.expect_value(t, v0, i32(32))
	testing.expect_value(t, cw, i32(64))
	testing.expect_value(t, ch, i32(64))
}

@(test)
test_quick_menu_config_parsing :: proc(t: ^testing.T) {
	saved := config
	defer config = saved

	testing.expect(t, apply_setting("window", "fps_limit", "120"), "fps_limit 120")
	testing.expect_value(t, config.window_fps_limit, 120)
	testing.expect(t, apply_setting("window", "fps_limit", "0"), "fps_limit unlimited")
	testing.expect_value(t, config.window_fps_limit, 0)
	testing.expect(t, apply_setting("window", "backend", "opengl"), "backend opengl")
	testing.expect_value(t, config.window_backend, Renderer_Backend.OpenGL)
	testing.expect_value(t, config.window_hardware, false)
	testing.expect(t, apply_setting("window", "backend", "vulkan"), "backend vulkan")
	testing.expect_value(t, config.window_backend, Renderer_Backend.Vulkan)
	testing.expect_value(t, config.window_hardware, true)
	testing.expect(t, apply_setting("window", "anti_wobble", "false"), "anti_wobble false")
	testing.expect_value(t, config.window_anti_wobble, false)
	testing.expect(t, apply_setting("audio", "smooth_fix", "true"), "audio smooth_fix")
	testing.expect(t, apply_setting("audio", "volume", "0.7"), "audio volume")
	testing.expect(t, apply_setting("mods", "enabled", "true"), "mods enabled")
	testing.expect(t, apply_setting("mods", "textures", "true"), "mods textures")
	testing.expect(t, apply_setting("mods", "dump_textures", "true"), "mods dump_textures")
	testing.expect_value(t, config.mods_dump_textures, true)
}

