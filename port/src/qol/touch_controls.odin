// On-screen PlayStation 1 DualShock / Digital touch controls.
//
// Design goals:
//   - Zero coordinate mismatch: hit-testing and rendering share the exact same
//     Touch_Layout in full physical screen coordinates (respecting Android
//     display cutout / notch safe-area insets).
//   - Zero axis or button inversion:
//       * Face diamond: Triangle (Top), Circle (Right), Cross (Bottom), Square (Left).
//       * D-pad: 8-way continuous angle sectors matching host.STICK_SECTORS.
//       * Analog sticks: +x = right, +y = down (matching SDL, core.stick_angle,
//         psx/bios/sio.odin, and qol/free_move.odin).
//   - Multi-touch finger capture: up to 10 simultaneous fingers tracked by
//     sdl.FingerID; dragging off a D-pad or stick keeps smooth control until
//     FINGERUP, and backgrounding clears every finger so nothing ever sticks.
//   - Ultra-fast GPU rendering: SDF anti-aliased PlayStation glyphs and glass
//     controls are pre-baked into SDL2 textures once, costing ~18 RenderCopy
//     calls (<0.1 ms) per frame with zero per-frame CPU pixel uploads.
//   - Auto-hide when using a physical gamepad (in .Auto mode), reappearing
//     instantly on screen touch.
package qol

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:sync"
import sdl "vendor:sdl2"

import "ps:core"
import host "ps:psx/host"

PS_ANDROID_PATCH :: #config(PS_ANDROID_PATCH, false)

@(private)
Touch_Mode :: enum u8 {
	Auto, // Android: shown until a gamepad is used; Desktop: shown on touch
	On,   // Always shown
	Off,  // Disabled
}

@(private)
TOUCH_MODE_TEXT := [Touch_Mode]string {
	.Auto = "Auto",
	.On   = "On",
	.Off  = "Off",
}

@(private)
TOUCH_MODE_KEYS := [Touch_Mode]string {
	.Auto = "auto",
	.On   = "on",
	.Off  = "off",
}

@(private)
Touch_Layout_Mode :: enum u8 {
	DualShock, // D-pad + Left/Right analog sticks + PS1 face/shoulder buttons
	Digital,   // Larger classic PS1 D-pad + face/shoulder buttons (no sticks)
	Analog,    // Large Left stick + Right stick + face/shoulder buttons
}

@(private)
TOUCH_LAYOUT_TEXT := [Touch_Layout_Mode]string {
	.DualShock = "DualShk",
	.Digital   = "Digital",
	.Analog    = "Analog",
}

@(private)
TOUCH_LAYOUT_KEYS := [Touch_Layout_Mode]string {
	.DualShock = "dualshock",
	.Digital   = "digital",
	.Analog    = "analog",
}

@(private = "file")
MAX_TOUCH_FINGERS :: 10

@(private = "file")
Finger_Role :: enum u8 {
	None,
	Dpad,
	Left_Stick,
	Right_Stick,
	Face_Buttons,
	Pill_Button,
	Pause_Pill,
	Style_Pill,
	Camera_Drag,
}

@(private = "file")
Active_Finger :: struct {
	active:   bool,
	id:       sdl.FingerID,
	role:     Finger_Role,
	bit:      u16,     // currently held PAD_* bit(s) for this finger
	last_x:   f32,     // last physical x (for camera drag)
	last_y:   f32,
	stick:    [2]f32,  // current stick vector (+x right, +y down)
	drag_acc: f32,     // cumulative drag distance to ignore accidental taps
}

@(private)
Touch_Circle :: struct {
	cx, cy, r: f32,
}

@(private)
Touch_Rect :: struct {
	x, y, w, h: f32,
}

@(private)
Face_Idx :: enum u8 {
	Triangle,
	Circle,
	Cross,
	Square,
}

@(private)
Pill_Idx :: enum u8 {
	L2,
	L1,
	R1,
	R2,
	Select,
	Start,
}

@(private)
FACE_BITS := [Face_Idx]u16 {
	.Triangle = host.PAD_TRIANGLE,
	.Circle   = host.PAD_CIRCLE,
	.Cross    = host.PAD_CROSS,
	.Square   = host.PAD_SQUARE,
}

@(private)
PILL_BITS := [Pill_Idx]u16 {
	.L2     = host.PAD_L2,
	.L1     = host.PAD_L1,
	.R1     = host.PAD_R1,
	.R2     = host.PAD_R2,
	.Select = host.PAD_SELECT,
	.Start  = host.PAD_START,
}

// Shared layout computed from physical screen size, safe insets, scale, and mode.
// Both hit-testing and rendering read from this exact struct.
@(private)
Touch_Layout :: struct {
	w, h:        f32,
	scale:       f32,
	mode:        Touch_Layout_Mode,
	has_dpad:    bool,
	has_lstick:  bool,
	has_rstick:  bool,
	dpad:        Touch_Circle,
	lstick:      Touch_Circle,
	rstick:      Touch_Circle,
	face_center: [2]f32,
	face:        [Face_Idx]Touch_Circle,
	pills:       [Pill_Idx]Touch_Rect,
	pause_pill:  Touch_Rect,
	style_pill:  Touch_Rect,
}

@(private = "file")
Touch_Sprites :: struct {
	ready:       bool,
	renderer:    ^sdl.Renderer,
	circle_bg:   ^sdl.Texture,
	circle_lit:  ^sdl.Texture,
	face_glyph:  [Face_Idx]^sdl.Texture,
	dpad_base:   ^sdl.Texture,
	dpad_dir:    [4]^sdl.Texture, // 0=Up, 1=Right, 2=Down, 3=Left
	stick_ring:  ^sdl.Texture,
	stick_knob:  ^sdl.Texture,
	pill_tex:    [Pill_Idx]^sdl.Texture,
	pill_lit:    [Pill_Idx]^sdl.Texture,
	pause_tex:   ^sdl.Texture,
	style_tex:   [Touch_Layout_Mode]^sdl.Texture,
}

@(private)
touch_state: struct {
	layout:          Touch_Layout,
	safe_insets:     [4]f32, // left, right, top, bottom in normalized 0..1
	fingers:         [MAX_TOUCH_FINGERS]Active_Finger,
	ever_touched:    bool,
	// Rising edge bits accumulated between game pad polls for quick-tap latching.
	edge_bits:       u16,
	// Accumulated horizontal camera touch-drag pixels (consumed by camera.odin).
	camera_drag_dx:  f32,
	// Deferred UI actions triggered on finger release (executed safely on main thread).
	want_pause:      bool,
	want_cycle_mode: bool,
	// Cached GPU textures (main/render thread only).
	sprites:         Touch_Sprites,
	// Fallback 640x480 OSD dirty tracking (only used when !PS_ANDROID_PATCH).
	osd_was_drawn:   bool,
	osd_last_held:   u16,
	osd_last_ls:     [2]f32,
	osd_last_rs:     [2]f32,
}

// Parse normalized safe-area inset environment variable (0.0 .. 0.15).
@(private = "file")
read_safe_inset :: proc(name: string) -> f32 {
	s := os.get_env(name, context.temp_allocator)
	if s == "" {
		return 0
	}
	v, ok := strconv.parse_f32(s)
	if !ok {
		return 0
	}
	return clamp(v, 0.0, 0.15)
}

@(private)
touch_init :: proc() {
	if core.headless {
		return
	}
	touch_state.safe_insets = {
		read_safe_inset("BOF4_SAFE_LEFT"),
		read_safe_inset("BOF4_SAFE_RIGHT"),
		read_safe_inset("BOF4_SAFE_TOP"),
		read_safe_inset("BOF4_SAFE_BOTTOM"),
	}
	// Default initial screen size (updated immediately from SDL renderer size).
	init_w: f32 = 1920 when ODIN_PLATFORM_SUBTARGET == .Android else 1280
	init_h: f32 = 1080 when ODIN_PLATFORM_SUBTARGET == .Android else 960
	when !PS_ANDROID_PATCH {
		init_w, init_h = f32(host.WINDOW_W), f32(host.WINDOW_H)
	}
	sync.mutex_lock(&gamepad_state.lock)
	touch_state.layout = touch_compute_layout(init_w, init_h, config.touch_layout, f32(config.touch_scale), touch_state.safe_insets)
	sync.mutex_unlock(&gamepad_state.lock)

	when PS_ANDROID_PATCH {
		host.overlay_render_hook = touch_render_sdl
	}
}

@(private)
touch_apply_config :: proc() {
	sync.mutex_lock(&gamepad_state.lock)
	l := &touch_state.layout
	touch_state.layout = touch_compute_layout(max(l.w, 320), max(l.h, 240), config.touch_layout, f32(config.touch_scale), touch_state.safe_insets)
	sync.mutex_unlock(&gamepad_state.lock)
}

// Compute the ergonomic PS1 touch controller layout for screen (w, h).
// Exported as @(private) so unit tests can verify zero overlaps and exact positions.
@(private)
touch_compute_layout :: proc(w, h: f32, mode: Touch_Layout_Mode, scale: f32, insets: [4]f32) -> (l: Touch_Layout) {
	l.w = max(w, 320)
	l.h = max(h, 240)
	l.mode = mode
	l.scale = clamp(scale, 0.6, 1.5)

	left := l.w * insets[0] + l.w * 0.015
	right := l.w * (1.0 - insets[1]) - l.w * 0.015
	top := l.h * insets[2] + l.h * 0.02
	bottom := l.h * (1.0 - insets[3]) - l.h * 0.02
	usable_w := max(right - left, 240)
	usable_h := max(bottom - top, 180)
	mid_x := (left + right) * 0.5

	// Scale unit based on shorter screen edge, clamped so controls never collide
	// horizontally even on narrow 4:3 displays.
	u := min(usable_h, usable_w * 0.72) * l.scale

	// Top shoulders: [ L2 ] [ L1 ] on top-left, [ R1 ] [ R2 ] on top-right.
	sh_w := 0.175 * u
	sh_h := 0.088 * u
	sh_gap := 0.028 * u
	sh_y := top + 0.015 * u
	l.pills[.L2] = {left + 0.02 * u, sh_y, sh_w, sh_h}
	l.pills[.L1] = {l.pills[.L2].x + sh_w + sh_gap, sh_y, sh_w, sh_h}
	l.pills[.R2] = {right - 0.02 * u - sh_w, sh_y, sh_w, sh_h}
	l.pills[.R1] = {l.pills[.R2].x - sh_gap - sh_w, sh_y, sh_w, sh_h}

	// Bottom center: [ SELECT ]   [ START ]
	cs_w := 0.16 * u
	cs_h := 0.068 * u
	cs_gap := 0.045 * u
	cs_y := bottom - cs_h - 0.015 * u
	l.pills[.Select] = {mid_x - cs_gap * 0.5 - cs_w, cs_y, cs_w, cs_h}
	l.pills[.Start] = {mid_x + cs_gap * 0.5, cs_y, cs_w, cs_h}

	// Top center subtle utility pills: [ || ] (Pause) and [ DS/DIG/ANA ] (Style)
	util_w := 0.115 * u
	util_h := 0.056 * u
	util_gap := 0.03 * u
	util_y := top + 0.01 * u
	l.pause_pill = {mid_x - util_gap * 0.5 - util_w, util_y, util_w, util_h}
	l.style_pill = {mid_x + util_gap * 0.5, util_y, util_w, util_h}

	// Left & Right primary controls by layout style.
	face_offset: f32
	face_r: f32
	switch mode {
	case .DualShock:
		l.has_dpad = true
		l.has_lstick = true
		l.has_rstick = true
		l.dpad = {left + 0.215 * u, bottom - 0.43 * u, 0.175 * u}
		l.lstick = {left + 0.455 * u, bottom - 0.185 * u, 0.135 * u}
		l.face_center = {right - 0.22 * u, bottom - 0.43 * u}
		l.rstick = {right - 0.455 * u, bottom - 0.185 * u, 0.135 * u}
		face_offset = 0.135 * u
		face_r = 0.076 * u
	case .Digital:
		l.has_dpad = true
		l.has_lstick = false
		l.has_rstick = false
		l.dpad = {left + 0.24 * u, bottom - 0.34 * u, 0.215 * u}
		l.face_center = {right - 0.24 * u, bottom - 0.34 * u}
		face_offset = 0.155 * u
		face_r = 0.088 * u
	case .Analog:
		l.has_dpad = false
		l.has_lstick = true
		l.has_rstick = true
		l.lstick = {left + 0.24 * u, bottom - 0.34 * u, 0.19 * u}
		l.face_center = {right - 0.22 * u, bottom - 0.43 * u}
		l.rstick = {right - 0.455 * u, bottom - 0.185 * u, 0.135 * u}
		face_offset = 0.135 * u
		face_r = 0.076 * u
	}

	// Authentic PlayStation Face Diamond:
	//   Triangle = TOP    (cy - offset)
	//   Circle   = RIGHT  (cx + offset)
	//   Cross    = BOTTOM (cy + offset)
	//   Square   = LEFT   (cx - offset)
	fcx, fcy := l.face_center.x, l.face_center.y
	l.face[.Triangle] = {fcx, fcy - face_offset, face_r}
	l.face[.Circle] = {fcx + face_offset, fcy, face_r}
	l.face[.Cross] = {fcx, fcy + face_offset, face_r}
	l.face[.Square] = {fcx - face_offset, fcy, face_r}
	return l
}

// Whether touch controls should currently be visible and active.
@(private)
touch_is_visible :: proc() -> bool {
	if core.headless {
		return false
	}
	switch config.touch_mode {
	case .Off:
		return false
	case .On:
		return true
	case .Auto:
		sync.mutex_lock(&gamepad_state.lock)
		gp_active := gamepad_state.gamepad_active
		touched := touch_state.ever_touched
		sync.mutex_unlock(&gamepad_state.lock)
		when ODIN_PLATFORM_SUBTARGET == .Android {
			return !gp_active
		} else {
			return touched && !gp_active
		}
	}
	return false
}

// Compute 8-way PS1 D-pad bits from a touch point relative to D-pad circle.
// Guaranteed exact orientation: Up = y < cy, Down = y > cy, Left = x < cx, Right = x > cx.
@(private)
touch_dpad_bits :: proc(dpad: Touch_Circle, px, py: f32) -> u16 {
	dx := px - dpad.cx
	dy := py - dpad.cy
	dist := math.sqrt(dx * dx + dy * dy)
	if dist < dpad.r * 0.16 {
		return 0
	}
	deg := math.to_degrees(math.atan2(f64(dx), f64(-dy)))
	sector := int(math.round(deg / 45.0)) & 7
	return host.STICK_SECTORS[sector]
}

// Compute analog stick vector (+x right, +y down, length 0..1) from touch point.
@(private)
touch_stick_vec :: proc(stick: Touch_Circle, px, py: f32) -> [2]f32 {
	if stick.r <= 0 {
		return {}
	}
	dx := px - stick.cx
	dy := py - stick.cy
	dist := math.sqrt(dx * dx + dy * dy)
	inner := stick.r * 0.08
	travel := max(stick.r * 0.72, inner + 1.0)
	if dist <= inner {
		return {}
	}
	mag := clamp((dist - inner) / (travel - inner), 0.0, 1.0)
	return {(dx / dist) * mag, (dy / dist) * mag}
}

@(private = "file")
point_in_circle :: proc(c: Touch_Circle, px, py: f32, pad_scale: f32 = 1.0) -> bool {
	if c.r <= 0 {
		return false
	}
	dx := px - c.cx
	dy := py - c.cy
	r := c.r * pad_scale
	return dx * dx + dy * dy <= r * r
}

@(private = "file")
point_in_rect :: proc(rc: Touch_Rect, px, py: f32, pad: f32 = 0) -> bool {
	return px >= rc.x - pad && px <= rc.x + rc.w + pad && py >= rc.y - pad && py <= rc.y + rc.h + pad
}

// Nearest face button within hitbox (prevents accidental double-presses like
// hitting Cancel while tapping Confirm; two separate fingers can still chord!).
@(private)
touch_hit_face :: proc(l: ^Touch_Layout, px, py: f32) -> (bit: u16, hit: bool) {
	best_d2 := max(f32)
	for fi in Face_Idx {
		c := l.face[fi]
		dx := px - c.cx
		dy := py - c.cy
		d2 := dx * dx + dy * dy
		max_r := c.r * 1.24
		if d2 <= max_r * max_r && d2 < best_d2 {
			best_d2 = d2
			bit = FACE_BITS[fi]
			hit = true
		}
	}
	return bit, hit
}

// Called with gamepad_state.lock held from input_event_watch.
@(private)
touch_handle_finger_locked :: proc(tf: sdl.TouchFingerEvent) {
	if config.touch_mode == .Off {
		return
	}
	touch_state.ever_touched = true
	l := &touch_state.layout
	px := clamp(tf.x, 0.0, 1.0) * l.w
	py := clamp(tf.y, 0.0, 1.0) * l.h

	#partial switch tf.type {
	case .FINGERDOWN:
		slot: ^Active_Finger = nil
		for &f in touch_state.fingers {
			if f.active && f.id == tf.fingerId {
				slot = &f
				break
			}
		}
		if slot == nil {
			for &f in touch_state.fingers {
				if !f.active {
					slot = &f
					break
				}
			}
		}
		if slot == nil {
			return
		}
		slot^ = Active_Finger{active = true, id = tf.fingerId, last_x = px, last_y = py}
		assign_finger_down_locked(slot, l, px, py)

	case .FINGERMOTION:
		for &f in touch_state.fingers {
			if f.active && f.id == tf.fingerId {
				update_finger_motion_locked(&f, l, px, py)
				return
			}
		}

	case .FINGERUP:
		for &f in touch_state.fingers {
			if f.active && f.id == tf.fingerId {
				if f.role == .Pause_Pill && point_in_rect(l.pause_pill, px, py, l.pause_pill.h * 0.35) {
					touch_state.want_pause = true
				} else if f.role == .Style_Pill && point_in_rect(l.style_pill, px, py, l.style_pill.h * 0.35) {
					touch_state.want_cycle_mode = true
				}
				f = {}
				return
			}
		}
	}
}

@(private = "file")
assign_finger_down_locked :: proc(f: ^Active_Finger, l: ^Touch_Layout, px, py: f32) {
	// 1. Utility pills (Pause / Style)
	if point_in_rect(l.pause_pill, px, py, l.pause_pill.h * 0.25) {
		f.role = .Pause_Pill
		return
	}
	if point_in_rect(l.style_pill, px, py, l.style_pill.h * 0.25) {
		f.role = .Style_Pill
		return
	}
	// 2. Shoulder & Select/Start pills
	for pi in Pill_Idx {
		rc := l.pills[pi]
		if point_in_rect(rc, px, py, rc.h * 0.22) {
			f.role = .Pill_Button
			f.bit = PILL_BITS[pi]
			touch_state.edge_bits |= f.bit
			return
		}
	}
	// 3. PS1 Face Buttons Diamond (Triangle / Circle / Cross / Square)
	if bit, ok := touch_hit_face(l, px, py); ok {
		f.role = .Face_Buttons
		f.bit = bit
		touch_state.edge_bits |= bit
		return
	}
	// 4. D-Pad (8-way slideable)
	if l.has_dpad && point_in_circle(l.dpad, px, py, 1.22) {
		f.role = .Dpad
		f.bit = touch_dpad_bits(l.dpad, px, py)
		touch_state.edge_bits |= f.bit
		return
	}
	// 5. Left Analog Stick
	if l.has_lstick && point_in_circle(l.lstick, px, py, 1.25) {
		f.role = .Left_Stick
		f.stick = touch_stick_vec(l.lstick, px, py)
		return
	}
	// 6. Right Analog Stick
	if l.has_rstick && point_in_circle(l.rstick, px, py, 1.25) {
		f.role = .Right_Stick
		f.stick = touch_stick_vec(l.rstick, px, py)
		return
	}
	// 7. Empty game area -> optional horizontal camera drag
	if config.touch_camera_drag {
		f.role = .Camera_Drag
		f.last_x = px
		f.last_y = py
		f.drag_acc = 0
	}
}

@(private = "file")
update_finger_motion_locked :: proc(f: ^Active_Finger, l: ^Touch_Layout, px, py: f32) {
	switch f.role {
	case .Dpad:
		next := touch_dpad_bits(l.dpad, px, py)
		rising := next & ~f.bit
		f.bit = next
		touch_state.edge_bits |= rising
	case .Left_Stick:
		f.stick = touch_stick_vec(l.lstick, px, py)
	case .Right_Stick:
		f.stick = touch_stick_vec(l.rstick, px, py)
	case .Face_Buttons:
		// Smooth thumb-slide across the 4 face buttons while staying near the diamond.
		if bit, ok := touch_hit_face(l, px, py); ok {
			rising := bit & ~f.bit
			f.bit = bit
			touch_state.edge_bits |= rising
		} else {
			// If slid far outside the diamond, release cleanly.
			dx := px - l.face_center.x
			dy := py - l.face_center.y
			bound := l.face[.Cross].r * 3.6
			if dx * dx + dy * dy > bound * bound {
				f.bit = 0
			}
		}
	case .Pill_Button:
		// Keep held while finger stays within a comfortable margin of the pill.
		kept := false
		for pi in Pill_Idx {
			if PILL_BITS[pi] == f.bit && point_in_rect(l.pills[pi], px, py, l.pills[pi].h * 0.55) {
				kept = true
				break
			}
		}
		if !kept {
			f.bit = 0
		}
	case .Camera_Drag:
		dx := px - f.last_x
		dy := py - f.last_y
		f.last_x = px
		f.last_y = py
		f.drag_acc += abs(dx) + abs(dy)
		if f.drag_acc > 8.0 {
			// Normalize to 640-wide logical pixels so sensitivity is consistent
			// across 720p, 1080p, and 1440p screens.
			touch_state.camera_drag_dx += dx * (640.0 / max(l.w, 1.0))
		}
	case .None, .Pause_Pill, .Style_Pill:
	}
}

@(private)
touch_clear_fingers_locked :: proc() {
	touch_state.fingers = {}
	touch_state.edge_bits = 0
	touch_state.camera_drag_dx = 0
}

// Read currently held touch buttons and consume any rising edge taps.
// Caller holds gamepad_state.lock.
@(private)
touch_consume_buttons_locked :: proc() -> (held, edge: u16) {
	if config.touch_mode == .Off {
		return 0, 0
	}
	for f in touch_state.fingers {
		if f.active {
			held |= f.bit
		}
	}
	edge = touch_state.edge_bits
	touch_state.edge_bits = 0
	return held, edge
}

// Read virtual touch Left & Right analog sticks (+x right, +y down).
// Caller holds gamepad_state.lock.
@(private)
touch_sticks_locked :: proc() -> (left, right: [2]f32) {
	if config.touch_mode == .Off {
		return {}, {}
	}
	for f in touch_state.fingers {
		if !f.active {
			continue
		}
		if f.role == .Left_Stick {
			left = core.stronger(left, f.stick)
		} else if f.role == .Right_Stick {
			right = core.stronger(right, f.stick)
		}
	}
	return left, right
}

// Consume accumulated center-screen touch camera drag (in 640px-normalized units).
@(private)
touch_consume_camera_drag :: proc() -> f32 {
	if core.headless || !config.touch_camera_drag || config.touch_mode == .Off {
		return 0
	}
	sync.mutex_lock(&gamepad_state.lock)
	dx := touch_state.camera_drag_dx
	touch_state.camera_drag_dx = 0
	sync.mutex_unlock(&gamepad_state.lock)
	return dx
}

@(private)
touch_toggle_pause :: proc() {
	when PS_ANDROID_PATCH {
		host.window_set_paused(!host.window_is_paused())
	} else {
		host.osd_toast("Pause")
	}
}

// Per-vblank touch housekeeping on the main thread (handles Pause/Style utility
// pill taps and fallback OSD overlay rendering when !PS_ANDROID_PATCH).
@(private)
touch_vblank :: proc() {
	if core.headless {
		return
	}
	do_pause, do_cycle := false, false
	sync.mutex_lock(&gamepad_state.lock)
	if touch_state.want_pause {
		touch_state.want_pause = false
		do_pause = true
	}
	if touch_state.want_cycle_mode {
		touch_state.want_cycle_mode = false
		do_cycle = true
	}
	sync.mutex_unlock(&gamepad_state.lock)

	if do_pause {
		touch_toggle_pause()
	}
	if do_cycle {
		next := Touch_Layout_Mode((int(config.touch_layout) + 1) % (int(max(Touch_Layout_Mode)) + 1))
		config.touch_layout = next
		touch_apply_config()
		host.osd_toast(fmt.tprintf("Pad: %s", TOUCH_LAYOUT_TEXT[next]))
	}

	when !PS_ANDROID_PATCH {
		touch_update_osd_fallback()
	}
}

// ============================================================================
// GPU-Accelerated SDL2 Touch Overlay Rendering (full physical screen space)
// ============================================================================

@(private)
touch_render_sdl :: proc(r: ^sdl.Renderer) {
	if r == nil || !touch_is_visible() {
		return
	}
	// Save host logical canvas state (640x480 4:3) and switch to full physical
	// window coordinates so controls sit cleanly on widescreen side margins.
	lw, lh: c.int
	sdl.RenderGetLogicalSize(r, &lw, &lh)
	int_scale := sdl.RenderGetIntegerScale(r)
	sdl.RenderSetLogicalSize(r, 0, 0)
	sdl.RenderSetViewport(r, nil)
	sdl.RenderSetScale(r, 1, 1)
	defer {
		if lw > 0 && lh > 0 {
			sdl.RenderSetLogicalSize(r, lw, lh)
			sdl.RenderSetIntegerScale(r, int_scale)
		}
	}

	ow, oh: c.int
	if sdl.GetRendererOutputSize(r, &ow, &oh) != 0 || ow <= 0 || oh <= 0 {
		return
	}

	// Update layout if window resized, rotated, or user changed scale/mode.
	sync.mutex_lock(&gamepad_state.lock)
	l := &touch_state.layout
	if abs(l.w - f32(ow)) > 0.5 || abs(l.h - f32(oh)) > 0.5 ||
		l.mode != config.touch_layout || abs(l.scale - f32(config.touch_scale)) > 0.001 {
		touch_state.layout = touch_compute_layout(f32(ow), f32(oh), config.touch_layout, f32(config.touch_scale), touch_state.safe_insets)
	}
	layout := touch_state.layout
	held: u16
	ls, rs: [2]f32
	pause_lit, style_lit := false, false
	for f in touch_state.fingers {
		if !f.active {
			continue
		}
		held |= f.bit
		if f.role == .Left_Stick { ls = core.stronger(ls, f.stick) }
		if f.role == .Right_Stick { rs = core.stronger(rs, f.stick) }
		if f.role == .Pause_Pill { pause_lit = true }
		if f.role == .Style_Pill { style_lit = true }
	}
	sync.mutex_unlock(&gamepad_state.lock)

	ensure_touch_sprites(r)
	sp := &touch_state.sprites
	if !sp.ready {
		return
	}

	base_alpha := u8(clamp(config.touch_opacity, 0.15, 1.0) * 255.0)
	lit_alpha := u8(min(f32(base_alpha) * 1.35 + 45.0, 255.0))
	util_alpha := u8(f32(base_alpha) * 0.72)

	// 1. Shoulder & Select/Start pills
	for pi in Pill_Idx {
		pressed := held & PILL_BITS[pi] != 0
		tex := pressed ? sp.pill_lit[pi] : sp.pill_tex[pi]
		rc := layout.pills[pi]
		dst := sdl.FRect{rc.x, rc.y, rc.w, rc.h}
		sdl.SetTextureAlphaMod(tex, pressed ? lit_alpha : base_alpha)
		sdl.RenderCopyF(r, tex, nil, &dst)
	}

	// 2. Utility pills (Pause & Style)
	{
		dst := sdl.FRect{layout.pause_pill.x, layout.pause_pill.y, layout.pause_pill.w, layout.pause_pill.h}
		sdl.SetTextureAlphaMod(sp.pause_tex, pause_lit ? lit_alpha : util_alpha)
		sdl.RenderCopyF(r, sp.pause_tex, nil, &dst)
	}
	{
		stex := sp.style_tex[layout.mode]
		dst := sdl.FRect{layout.style_pill.x, layout.style_pill.y, layout.style_pill.w, layout.style_pill.h}
		sdl.SetTextureAlphaMod(stex, style_lit ? lit_alpha : util_alpha)
		sdl.RenderCopyF(r, stex, nil, &dst)
	}

	// 3. D-Pad
	if layout.has_dpad {
		c := layout.dpad
		dst := sdl.FRect{c.cx - c.r, c.cy - c.r, c.r * 2, c.r * 2}
		sdl.SetTextureAlphaMod(sp.dpad_base, base_alpha)
		sdl.RenderCopyF(r, sp.dpad_base, nil, &dst)
		dir_bits := [4]u16{host.PAD_UP, host.PAD_RIGHT, host.PAD_DOWN, host.PAD_LEFT}
		for b, i in dir_bits {
			if held & b != 0 {
				sdl.SetTextureAlphaMod(sp.dpad_dir[i], lit_alpha)
				sdl.RenderCopyF(r, sp.dpad_dir[i], nil, &dst)
			}
		}
	}

	// 4. Left & Right Analog Sticks
	if layout.has_lstick {
		draw_stick_sdl(r, sp, layout.lstick, ls, base_alpha, lit_alpha)
	}
	if layout.has_rstick {
		draw_stick_sdl(r, sp, layout.rstick, rs, base_alpha, lit_alpha)
	}

	// 5. PS1 Face Buttons Diamond (Triangle, Circle, Cross, Square)
	for fi in Face_Idx {
		c := layout.face[fi]
		pressed := held & FACE_BITS[fi] != 0
		dst := sdl.FRect{c.cx - c.r, c.cy - c.r, c.r * 2, c.r * 2}
		bg := pressed ? sp.circle_lit : sp.circle_bg
		sdl.SetTextureAlphaMod(bg, pressed ? lit_alpha : base_alpha)
		sdl.RenderCopyF(r, bg, nil, &dst)
		glyph := sp.face_glyph[fi]
		sdl.SetTextureAlphaMod(glyph, pressed ? 255 : base_alpha)
		sdl.RenderCopyF(r, glyph, nil, &dst)
	}
}

@(private = "file")
draw_stick_sdl :: proc(r: ^sdl.Renderer, sp: ^Touch_Sprites, c: Touch_Circle, v: [2]f32, base_alpha, lit_alpha: u8) {
	ring_dst := sdl.FRect{c.cx - c.r, c.cy - c.r, c.r * 2, c.r * 2}
	sdl.SetTextureAlphaMod(sp.stick_ring, base_alpha)
	sdl.RenderCopyF(r, sp.stick_ring, nil, &ring_dst)

	travel := c.r * 0.72
	kx := c.cx + v.x * travel
	ky := c.cy + v.y * travel
	kr := c.r * 0.44
	knob_dst := sdl.FRect{kx - kr, ky - kr, kr * 2, kr * 2}
	active := v != {}
	sdl.SetTextureAlphaMod(sp.stick_knob, active ? lit_alpha : base_alpha)
	sdl.RenderCopyF(r, sp.stick_knob, nil, &knob_dst)
}

// ============================================================================
// Procedural SDF Anti-Aliased PlayStation Button Sprite Baker (Zero Assets!)
// ============================================================================

@(private = "file")
make_argb_tex :: proc(r: ^sdl.Renderer, w, h: i32, pixels: []u32) -> ^sdl.Texture {
	tex := sdl.CreateTexture(r, .ARGB8888, .STATIC, w, h)
	if tex == nil {
		return nil
	}
	sdl.SetTextureBlendMode(tex, .BLEND)
	sdl.SetTextureScaleMode(tex, .Linear)
	sdl.UpdateTexture(tex, nil, raw_data(pixels), w * 4)
	return tex
}

@(private = "file")
argb :: #force_inline proc(a, r, g, b: u8) -> u32 {
	return u32(a) << 24 | u32(r) << 16 | u32(g) << 8 | u32(b)
}

@(private = "file")
smoothstep :: #force_inline proc(edge0, edge1, x: f32) -> f32 {
	t := clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
}

@(private = "file")
blend_over :: #force_inline proc(dst, src: u32) -> u32 {
	sa := f32((src >> 24) & 0xff) / 255.0
	if sa <= 0 {
		return dst
	}
	if sa >= 1 {
		return src
	}
	da := f32((dst >> 24) & 0xff) / 255.0
	out_a := sa + da * (1.0 - sa)
	if out_a <= 0 {
		return 0
	}
	sr, sg, sb := f32((src >> 16) & 0xff), f32((src >> 8) & 0xff), f32(src & 0xff)
	dr, dg, db := f32((dst >> 16) & 0xff), f32((dst >> 8) & 0xff), f32(dst & 0xff)
	rr := (sr * sa + dr * da * (1.0 - sa)) / out_a
	rg := (sg * sa + dg * da * (1.0 - sa)) / out_a
	rb := (sb * sa + db * da * (1.0 - sa)) / out_a
	return argb(u8(clamp(out_a * 255.0, 0, 255)), u8(clamp(rr, 0, 255)), u8(clamp(rg, 0, 255)), u8(clamp(rb, 0, 255)))
}

@(private = "file")
sd_segment :: proc(px, py, ax, ay, bx, by: f32) -> f32 {
	pax, pay := px - ax, py - ay
	bax, bay := bx - ax, by - ay
	denom := bax * bax + bay * bay
	h := denom > 1e-6 ? clamp((pax * bax + pay * bay) / denom, 0.0, 1.0) : 0.0
	dx, dy := pax - bax * h, pay - bay * h
	return math.sqrt(dx * dx + dy * dy)
}

@(private = "file")
sd_rounded_box :: proc(px, py, bx, by, r: f32) -> f32 {
	qx := abs(px) - bx + r
	qy := abs(py) - by + r
	mx, my := max(qx, 0.0), max(qy, 0.0)
	return math.sqrt(mx * mx + my * my) + min(max(qx, qy), 0.0) - r
}

@(private = "file")
bake_circle_button :: proc(r: ^sdl.Renderer, lit: bool) -> ^sdl.Texture {
	S :: 96
	buf := make([]u32, S * S, context.temp_allocator)
	half := f32(S) * 0.5
	rad := half - 3.0
	for y in 0 ..< S {
		for x in 0 ..< S {
			dx := (f32(x) + 0.5) - half
			dy := (f32(y) + 0.5) - half
			d := math.sqrt(dx * dx + dy * dy) - rad
			fill_a := 1.0 - smoothstep(-1.2, 1.2, d)
			ring_a := (1.0 - smoothstep(1.2, 2.8, abs(d + 1.5)))
			c: u32 = 0
			if fill_a > 0 {
				if lit {
					c = argb(u8(fill_a * 175.0), 82, 118, 178)
				} else {
					c = argb(u8(fill_a * 125.0), 18, 22, 30)
				}
			}
			if ring_a > 0 {
				border := lit ? argb(u8(ring_a * 245.0), 215, 232, 255) : argb(u8(ring_a * 190.0), 210, 218, 232)
				c = blend_over(c, border)
			}
			buf[y * S + x] = c
		}
	}
	return make_argb_tex(r, S, S, buf)
}

@(private = "file")
bake_face_glyph :: proc(r: ^sdl.Renderer, fi: Face_Idx) -> ^sdl.Texture {
	S :: 96
	buf := make([]u32, S * S, context.temp_allocator)
	half := f32(S) * 0.5
	stroke := f32(3.6)

	// Authentic PlayStation button colors:
	// Triangle = Emerald Green, Circle = Coral Red, Cross = Periwinkle Blue, Square = Rose Pink
	col: [3]u8
	switch fi {
	case .Triangle: col = {56, 218, 162}
	case .Circle:   col = {245, 98, 108}
	case .Cross:    col = {112, 162, 255}
	case .Square:   col = {236, 128, 192}
	}

	for y in 0 ..< S {
		for x in 0 ..< S {
			px := (f32(x) + 0.5) - half
			py := (f32(y) + 0.5) - half
			dist: f32 = 999.0
			switch fi {
			case .Triangle:
				// Equilateral triangle pointing UP
				ax, ay := f32(0), f32(-21)
				bx, by := f32(20), f32(15)
				cx, cy := f32(-20), f32(15)
				d1 := sd_segment(px, py, ax, ay, bx, by)
				d2 := sd_segment(px, py, bx, by, cx, cy)
				d3 := sd_segment(px, py, cx, cy, ax, ay)
				dist = min(d1, min(d2, d3))
			case .Circle:
				dist = abs(math.sqrt(px * px + py * py) - 18.5)
			case .Cross:
				d1 := sd_segment(px, py, -16, -16, 16, 16)
				d2 := sd_segment(px, py, 16, -16, -16, 16)
				dist = min(d1, d2)
			case .Square:
				dist = abs(sd_rounded_box(px, py, 16.5, 16.5, 2.0))
			}
			a := 1.0 - smoothstep(stroke - 1.2, stroke + 1.2, dist)
			if a > 0 {
				buf[y * S + x] = argb(u8(a * 255.0), col[0], col[1], col[2])
			}
		}
	}
	return make_argb_tex(r, S, S, buf)
}

@(private = "file")
bake_dpad_base :: proc(r: ^sdl.Renderer) -> ^sdl.Texture {
	S :: 160
	buf := make([]u32, S * S, context.temp_allocator)
	half := f32(S) * 0.5
	for y in 0 ..< S {
		for x in 0 ..< S {
			px := (f32(x) + 0.5) - half
			py := (f32(y) + 0.5) - half
			// Subtle circular backing ring
			cd := math.sqrt(px * px + py * py) - (half - 4.0)
			bg_a := 1.0 - smoothstep(-1.5, 1.5, cd)
			ring_a := 1.0 - smoothstep(1.0, 2.5, abs(cd + 1.5))
			// Classic PS1 cross silhouette (horizontal + vertical rounded bars)
			dh := sd_rounded_box(px, py, 64, 22, 8)
			dv := sd_rounded_box(px, py, 22, 64, 8)
			d_cross := min(dh, dv)
			cross_a := 1.0 - smoothstep(-1.2, 1.2, d_cross)
			cross_edge := 1.0 - smoothstep(0.8, 2.2, abs(d_cross + 1.0))

			c: u32 = 0
			if bg_a > 0 {
				c = argb(u8(bg_a * 65.0), 14, 18, 26)
			}
			if ring_a > 0 {
				c = blend_over(c, argb(u8(ring_a * 115.0), 195, 206, 224))
			}
			if cross_a > 0 {
				c = blend_over(c, argb(u8(cross_a * 145.0), 28, 34, 46))
			}
			if cross_edge > 0 {
				c = blend_over(c, argb(u8(cross_edge * 205.0), 210, 220, 236))
			}
			// Center subtle dimple
			dimple := math.sqrt(px * px + py * py) - 10.0
			if dimple < 0 {
				da := 1.0 - smoothstep(-2.0, 0.0, dimple)
				c = blend_over(c, argb(u8(da * 70.0), 10, 12, 16))
			}
			buf[y * S + x] = c
		}
	}
	return make_argb_tex(r, S, S, buf)
}

// Bake directional lit overlay for D-pad arm (dir: 0=Up, 1=Right, 2=Down, 3=Left).
@(private = "file")
bake_dpad_dir :: proc(r: ^sdl.Renderer, dir: int) -> ^sdl.Texture {
	S :: 160
	buf := make([]u32, S * S, context.temp_allocator)
	half := f32(S) * 0.5
	for y in 0 ..< S {
		for x in 0 ..< S {
			px := (f32(x) + 0.5) - half
			py := (f32(y) + 0.5) - half
			// Rotate into Up-facing local frame
			lx, ly: f32
			switch dir {
			case 0: lx, ly = px, py          // Up (ly < 0)
			case 1: lx, ly = py, -px         // Right
			case 2: lx, ly = -px, -py        // Down
			case 3: lx, ly = -py, px         // Left
			}
			// Arm box in upper half (-62 .. -16)
			d := sd_rounded_box(lx, ly + 39.0, 19.0, 23.0, 6.0)
			a := 1.0 - smoothstep(-1.2, 1.2, d)
			if a > 0 {
				buf[y * S + x] = argb(u8(a * 195.0), 112, 168, 255)
			}
		}
	}
	return make_argb_tex(r, S, S, buf)
}

@(private = "file")
bake_stick_ring :: proc(r: ^sdl.Renderer) -> ^sdl.Texture {
	S :: 128
	buf := make([]u32, S * S, context.temp_allocator)
	half := f32(S) * 0.5
	rad := half - 4.0
	for y in 0 ..< S {
		for x in 0 ..< S {
			px := (f32(x) + 0.5) - half
			py := (f32(y) + 0.5) - half
			d := math.sqrt(px * px + py * py) - rad
			fill_a := 1.0 - smoothstep(-1.2, 1.2, d)
			ring_a := 1.0 - smoothstep(1.2, 2.8, abs(d + 1.5))
			c: u32 = 0
			if fill_a > 0 {
				c = argb(u8(fill_a * 82.0), 16, 20, 28)
			}
			if ring_a > 0 {
				c = blend_over(c, argb(u8(ring_a * 175.0), 200, 212, 230))
			}
			buf[y * S + x] = c
		}
	}
	return make_argb_tex(r, S, S, buf)
}

@(private = "file")
bake_stick_knob :: proc(r: ^sdl.Renderer) -> ^sdl.Texture {
	S :: 96
	buf := make([]u32, S * S, context.temp_allocator)
	half := f32(S) * 0.5
	rad := half - 3.0
	for y in 0 ..< S {
		for x in 0 ..< S {
			px := (f32(x) + 0.5) - half
			py := (f32(y) + 0.5) - half
			dist := math.sqrt(px * px + py * py)
			d := dist - rad
			fill_a := 1.0 - smoothstep(-1.2, 1.2, d)
			outer_ring := 1.0 - smoothstep(1.2, 2.8, abs(d + 2.0))
			inner_ring := 1.0 - smoothstep(1.0, 2.2, abs(dist - rad * 0.62))
			c: u32 = 0
			if fill_a > 0 {
				c = argb(u8(fill_a * 190.0), 46, 56, 74)
			}
			if inner_ring > 0 {
				c = blend_over(c, argb(u8(inner_ring * 130.0), 170, 185, 210))
			}
			if outer_ring > 0 {
				c = blend_over(c, argb(u8(outer_ring * 235.0), 220, 230, 245))
			}
			buf[y * S + x] = c
		}
	}
	return make_argb_tex(r, S, S, buf)
}

// Tiny crisp 5x7 uppercase bitmap font for shoulder/start/select pill labels.
@(private = "file")
pill_glyph_rows :: proc(ch: u8) -> [7]u8 {
	switch ch {
	case 'L': return {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f}
	case 'R': return {0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11}
	case '1': return {0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e}
	case '2': return {0x0e, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1f}
	case 'S': return {0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e}
	case 'E': return {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f}
	case 'C': return {0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e}
	case 'T': return {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}
	case 'A': return {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}
	case 'D': return {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e}
	case 'I': return {0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e}
	case 'G': return {0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0e}
	case 'N': return {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11}
	case '|': return {0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a}
	}
	return {}
}

@(private = "file")
bake_pill :: proc(r: ^sdl.Renderer, label: string, lit: bool) -> ^sdl.Texture {
	W :: 128
	H :: 56
	buf := make([]u32, W * H, context.temp_allocator)
	hw, hh := f32(W) * 0.5, f32(H) * 0.5
	for y in 0 ..< H {
		for x in 0 ..< W {
			px := (f32(x) + 0.5) - hw
			py := (f32(y) + 0.5) - hh
			d := sd_rounded_box(px, py, hw - 3.0, hh - 3.0, hh - 4.0)
			fill_a := 1.0 - smoothstep(-1.2, 1.2, d)
			ring_a := 1.0 - smoothstep(1.0, 2.4, abs(d + 1.5))
			c: u32 = 0
			if fill_a > 0 {
				c = lit ? argb(u8(fill_a * 185.0), 82, 122, 186) : argb(u8(fill_a * 130.0), 20, 24, 34)
			}
			if ring_a > 0 {
				border := lit ? argb(u8(ring_a * 245.0), 225, 238, 255) : argb(u8(ring_a * 190.0), 205, 215, 232)
				c = blend_over(c, border)
			}
			buf[y * W + x] = c
		}
	}
	// Draw centered crisp label using 3x-scaled 5x7 glyphs
	scale := len(label) >= 5 ? 2 : 3
	char_w := 6 * scale
	text_w := len(label) * char_w - scale
	text_h := 7 * scale
	ox := (W - text_w) / 2
	oy := (H - text_h) / 2
	fg := lit ? argb(255, 255, 255, 255) : argb(235, 230, 236, 248)
	for i in 0 ..< len(label) {
		rows := pill_glyph_rows(label[i])
		for ry in 0 ..< 7 {
			bits := rows[ry]
			for rx in 0 ..< 5 {
				if bits & (1 << uint(4 - rx)) == 0 {
					continue
				}
				for sy in 0 ..< scale {
					for sx in 0 ..< scale {
						px := ox + i * char_w + rx * scale + sx
						py := oy + ry * scale + sy
						if px >= 0 && px < W && py >= 0 && py < H {
							buf[py * W + px] = blend_over(buf[py * W + px], fg)
						}
					}
				}
			}
		}
	}
	return make_argb_tex(r, W, H, buf)
}

@(private = "file")
ensure_touch_sprites :: proc(r: ^sdl.Renderer) {
	sp := &touch_state.sprites
	if sp.ready && sp.renderer == r {
		return
	}
	sp^ = {renderer = r}
	sp.circle_bg = bake_circle_button(r, false)
	sp.circle_lit = bake_circle_button(r, true)
	for fi in Face_Idx {
		sp.face_glyph[fi] = bake_face_glyph(r, fi)
	}
	sp.dpad_base = bake_dpad_base(r)
	for d in 0 ..< 4 {
		sp.dpad_dir[d] = bake_dpad_dir(r, d)
	}
	sp.stick_ring = bake_stick_ring(r)
	sp.stick_knob = bake_stick_knob(r)
	pill_labels := [Pill_Idx]string{
		.L2     = "L2",
		.L1     = "L1",
		.R1     = "R1",
		.R2     = "R2",
		.Select = "SELECT",
		.Start  = "START",
	}
	for pi in Pill_Idx {
		sp.pill_tex[pi] = bake_pill(r, pill_labels[pi], false)
		sp.pill_lit[pi] = bake_pill(r, pill_labels[pi], true)
	}
	sp.pause_tex = bake_pill(r, "|", false)
	sp.style_tex[.DualShock] = bake_pill(r, "DS", false)
	sp.style_tex[.Digital] = bake_pill(r, "DIG", false)
	sp.style_tex[.Analog] = bake_pill(r, "ANA", false)
	sp.ready = sp.circle_bg != nil && sp.dpad_base != nil && sp.stick_ring != nil
}

// ============================================================================
// Stock ps-recomp Fallback Overlay (640x480 host.osd_overlay_pixels)
// Used only when compiled without PS_ANDROID_PATCH (unpatched desktop builds).
// ============================================================================

@(private = "file")
touch_update_osd_fallback :: proc() {
	// Never overwrite the map editor's overlay when active.
	if map_editor.on {
		return
	}
	if !touch_is_visible() {
		if touch_state.osd_was_drawn {
			touch_state.osd_was_drawn = false
			host.osd_overlay_shown = false
		}
		return
	}
	sync.mutex_lock(&gamepad_state.lock)
	if touch_state.layout.w != f32(host.WINDOW_W) || touch_state.layout.h != f32(host.WINDOW_H) ||
		touch_state.layout.mode != config.touch_layout || abs(touch_state.layout.scale - f32(config.touch_scale)) > 0.001 {
		touch_state.layout = touch_compute_layout(f32(host.WINDOW_W), f32(host.WINDOW_H), config.touch_layout, f32(config.touch_scale), touch_state.safe_insets)
	}
	layout := touch_state.layout
	held: u16
	ls, rs: [2]f32
	for f in touch_state.fingers {
		if !f.active {
			continue
		}
		held |= f.bit
		if f.role == .Left_Stick { ls = core.stronger(ls, f.stick) }
		if f.role == .Right_Stick { rs = core.stronger(rs, f.stick) }
	}
	sync.mutex_unlock(&gamepad_state.lock)

	if touch_state.osd_was_drawn && held == touch_state.osd_last_held && ls == touch_state.osd_last_ls && rs == touch_state.osd_last_rs {
		return
	}
	touch_state.osd_was_drawn = true
	touch_state.osd_last_held = held
	touch_state.osd_last_ls = ls
	touch_state.osd_last_rs = rs

	pix := host.osd_overlay_pixels[:]
	for &p in pix {
		p = 0
	}
	a := u8(clamp(config.touch_opacity, 0.15, 1.0) * 180.0)
	base_col := argb(a, 24, 30, 42)
	lit_col := argb(min(a + 65, 255), 100, 155, 245)
	ring_col := argb(min(a + 50, 255), 210, 220, 236)

	for pi in Pill_Idx {
		rc := layout.pills[pi]
		fill_rect_osd(pix, int(rc.x), int(rc.y), int(rc.w), int(rc.h), held & PILL_BITS[pi] != 0 ? lit_col : base_col, ring_col)
	}
	if layout.has_dpad {
		draw_circle_osd(pix, layout.dpad, held & (host.PAD_UP | host.PAD_DOWN | host.PAD_LEFT | host.PAD_RIGHT) != 0 ? lit_col : base_col, ring_col)
	}
	if layout.has_lstick {
		draw_circle_osd(pix, layout.lstick, base_col, ring_col)
		tr := layout.lstick.r * 0.72
		draw_circle_osd(pix, {layout.lstick.cx + ls.x * tr, layout.lstick.cy + ls.y * tr, layout.lstick.r * 0.42}, ls != {} ? lit_col : ring_col, ring_col)
	}
	if layout.has_rstick {
		draw_circle_osd(pix, layout.rstick, base_col, ring_col)
		tr := layout.rstick.r * 0.72
		draw_circle_osd(pix, {layout.rstick.cx + rs.x * tr, layout.rstick.cy + rs.y * tr, layout.rstick.r * 0.42}, rs != {} ? lit_col : ring_col, ring_col)
	}
	face_cols := [Face_Idx]u32{
		.Triangle = argb(min(a + 65, 255), 56, 218, 162),
		.Circle   = argb(min(a + 65, 255), 245, 98, 108),
		.Cross    = argb(min(a + 65, 255), 112, 162, 255),
		.Square   = argb(min(a + 65, 255), 236, 128, 192),
	}
	for fi in Face_Idx {
		draw_circle_osd(pix, layout.face[fi], held & FACE_BITS[fi] != 0 ? lit_col : base_col, face_cols[fi])
	}
	host.osd_overlay_shown = true
	host.osd_overlay_changed()
}

@(private = "file")
fill_rect_osd :: proc(pix: []u32, x0, y0, w, h: int, fill, border: u32) {
	for y in max(y0, 0) ..< min(y0 + h, host.WINDOW_H) {
		for x in max(x0, 0) ..< min(x0 + w, host.WINDOW_W) {
			edge := x == x0 || x == x0 + w - 1 || y == y0 || y == y0 + h - 1
			pix[y * host.WINDOW_W + x] = edge ? border : fill
		}
	}
}

@(private = "file")
draw_circle_osd :: proc(pix: []u32, c: Touch_Circle, fill, border: u32) {
	r := int(math.ceil(c.r))
	cx, cy := int(c.cx), int(c.cy)
	r2 := c.r * c.r
	in2 := (c.r - 2.0) * (c.r - 2.0)
	for y in max(cy - r, 0) ..< min(cy + r + 1, host.WINDOW_H) {
		dy := f32(y) - c.cy
		for x in max(cx - r, 0) ..< min(cx + r + 1, host.WINDOW_W) {
			dx := f32(x) - c.cx
			d2 := dx * dx + dy * dy
			if d2 <= r2 {
				pix[y * host.WINDOW_W + x] = d2 >= in2 ? border : fill
			}
		}
	}
}
