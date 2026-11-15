// Unified, low-latency gamepad and touch input pipeline.
//
// Solves the classic Android and cross-platform controller pitfalls:
//   1. Sets SDL hints BEFORE SDL_Init (via gamepad_boot_hints in qol.boot):
//      - Disables Android accelerometer-as-joystick impersonation.
//      - Forces positional face buttons (South=Cross, East=Circle, West=Square,
//        North=Triangle) across PlayStation, Xbox, Nintendo Switch, and 8BitDo.
//      - Disables synthetic touch->mouse events so screen touches never click
//        Mouse Left (PAD_CROSS) or hijack mouse_menus.
//      - Traps Android's Back button so gamepads do not accidentally quit.
//   2. Loads embedded SDL_GameControllerDB mappings (gamepad_db.odin) plus any
//      user gamecontrollerdb.txt before enumerating already-connected pads.
//   3. Provides a raw SDL_Joystick fallback for unmapped Bluetooth/USB Android
//      and Linux controllers (ignoring accelerometers/sensors), with automatic
//      unipolar (0..32767) vs bipolar (-32768..32767) trigger calibration.
//   4. Enforces exact PS1 / SDL stick sign convention everywhere:
//      +x = right, +y = down (NEVER negated/inverted), with configurable radial
//      deadzone and snappy trigger threshold with release hysteresis.
//   5. Eliminates missed quick taps on 30 fps game ticks via a short 2-poll
//      release latch (zero delay on press, zero delay on normal release).
//   6. Auto-hides on-screen touch controls as soon as a physical gamepad is
//      used, and restores authentic PlayStation prompts on touch.
package qol

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl2"

import "ps:core"
import bios "ps:psx/bios"
import cpu "ps:psx/cpu"
import host "ps:psx/host"
import io "ps:psx/io"

// Number of game pad polls a rapid tap is guaranteed to remain visible if the
// button was released before the game could sample it (BOF4 field/battle runs
// at 30 fps = 1 tick per 2 vblanks). Never delays press or held releases.
@(private)
TAP_LATCH_POLLS :: 2

// Hysteresis margin below config.pad_trigger_threshold for clean trigger release.
@(private = "file")
TRIGGER_HYSTERESIS :: f32(0.05)

// Maximum unmapped generic joysticks tracked alongside SDL_GameController slots.
@(private = "file")
MAX_GENERIC_JOYS :: 4

// Minimum buttons for a raw joystick to be considered a real gamepad (filters
// out accelerometers, volume rockers, and sensor pseudo-joysticks).
@(private = "file")
MIN_GAMEPAD_BUTTONS :: 6

// Fallback generic joystick entry for controllers not in GameControllerDB.
@(private = "file")
Generic_Joy :: struct {
	joy:               ^sdl.Joystick,
	id:                sdl.JoystickID,
	num_buttons:       c.int,
	num_axes:          c.int,
	num_hats:          c.int,
	// Whether trigger axes 4/5 rest at -32768 (bipolar) vs 0 (unipolar).
	l2_bipolar:        bool,
	r2_bipolar:        bool,
	// Hysteresis state for triggers.
	l2_pressed:        bool,
	r2_pressed:        bool,
	is_android_layout: bool,
}

// Per-button quick-tap latch: counts down each time the game polls the pad.
// A bit stays asserted while (live_held & bit != 0) || (polls_left[i] > 0).
@(private)
Button_Latch :: struct {
	prev_live:  u16,
	polls_left: [16]u8,
}

@(private)
gamepad_state: struct {
	lock:             sync.Mutex,
	initialized:      bool,
	// Chained host.pad_hook (e.g. mouse_menus) installed before or alongside us.
	prev_pad_hook:    proc(held: u16) -> u16,
	// Generic SDL_Joystick fallback slots.
	generic:          [MAX_GENERIC_JOYS]Generic_Joy,
	// Hysteresis state for SDL_GameController triggers (with custom threshold).
	gc_l2_held:       bool,
	gc_r2_held:       bool,
	// Quick-tap latches for physical controllers and touch controls.
	pad_latch:        Button_Latch,
	touch_latch:      Button_Latch,
	// Event-watch latched presses arriving between polls (cleared on consume).
	watch_pad_press:  u16,
	// Last vblank present counter at which live events were pumped.
	last_pump_vblank: u64,
	// True once a physical gamepad was used more recently than touch.
	gamepad_active:   bool,
	// Deferred low-memory flag raised by SDL_APP_LOWMEMORY on the Android UI thread.
	low_memory_flag:  bool,
}

// Set critical SDL2 hints BEFORE SDL_Init runs inside host.platform_init.
// Called from qol.boot() (which psx.run invokes before host.platform_init).
@(private)
gamepad_boot_hints :: proc() {
	if core.headless {
		return
	}
	// Never treat an Android phone's built-in accelerometer as joystick 0.
	sdl.SetHint(sdl.HINT_ACCELEROMETER_AS_JOYSTICK, "0")
	// Always map face buttons by physical position (South=A/Cross, East=B/Circle,
	// West=X/Square, North=Y/Triangle) so Nintendo/8BitDo pads are never inverted.
	sdl.SetHint(sdl.HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0")
	// Stop SDL from turning finger touches into fake mouse clicks (Mouse Left = Cross).
	sdl.SetHint(sdl.HINT_TOUCH_MOUSE_EVENTS, "0")
	sdl.SetHint(sdl.HINT_MOUSE_TOUCH_EVENTS, "0")
	// Keep Android Back button inside the app instead of killing the activity.
	sdl.SetHint(sdl.HINT_ANDROID_TRAP_BACK_BUTTON, "1")
	// Pause smoothly when backgrounded on Android.
	sdl.SetHint(sdl.HINT_ANDROID_BLOCK_ON_PAUSE, "1")
	sdl.SetHint(sdl.HINT_ANDROID_BLOCK_ON_PAUSE_PAUSEAUDIO, "1")
	// Enable HIDAPI drivers for modern PlayStation / Xbox / Switch / 8BitDo pads.
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS4, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS5, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_SWITCH, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_XBOX, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_XBOX_ONE, "1")
}

// Initialize embedded controller mappings, generic joystick fallback, event
// filters, and unified pad/stick hooks. Called from qol.init() after SDL_Init.
@(private)
gamepad_init :: proc() {
	if core.headless || gamepad_state.initialized {
		return
	}
	gamepad_state.initialized = true
	core.input.rumble_strength = f32(clamp(config.pad_rumble, 0, 1))

	// Load embedded GameControllerDB mappings so Android & USB/BT pads work
	// even without an external gamecontrollerdb.txt.
	db := EMBEDDED_GAMECONTROLLERDB
	if len(db) > 0 {
		rw := sdl.RWFromConstMem(raw_data(db), c.int(len(db)))
		if rw != nil {
			n := sdl.GameControllerAddMappingsFromRW(rw, true)
			if n < 0 {
				fmt.eprintln("gamepad: embedded mapping db warning:", sdl.GetError())
			}
		}
	}
	// Reload optional user override file so custom entries take precedence.
	if os.exists(core.CONTROLLER_DB_FILE) {
		sdl.GameControllerAddMappingsFromFile(core.CONTROLLER_DB_FILE)
	}

	// Scan devices already attached at startup (Bluetooth/USB pads paired before launch).
	n_joy := sdl.NumJoysticks()
	for i: c.int = 0; i < n_joy; i += 1 {
		gamepad_try_attach(i)
	}

	// Drop synthetic touch-to-mouse events before they can enter SDL's queue.
	sdl.SetEventFilter(input_event_filter, nil)
	// Observe touch, gamepad, and Android lifecycle events with zero queue delay.
	sdl.AddEventWatch(input_event_watch, nil)

	// Chain onto host.pad_hook (preserving mouse_menus or any earlier hook).
	if host.pad_hook != input_pad_hook {
		gamepad_state.prev_pad_hook = host.pad_hook
		host.pad_hook = input_pad_hook
	}
	// Route BIOS DualShock analog sticks and rumble through our unified pipeline.
	bios.sticks = proc() -> (left, right: [2]f32) {
		s := input_sticks()
		return s.left, s.right
	}
	bios.pad_rumble = input_pad_rumble
}

// Apply live config changes from Setting > Extras > Controls.
@(private)
gamepad_apply_config :: proc() {
	core.input.rumble_strength = f32(clamp(config.pad_rumble, 0, 1))
}

// Per-vblank housekeeping on the main thread.
@(private)
gamepad_vblank :: proc() {
	if core.headless || !gamepad_state.initialized {
		return
	}
	// Handle deferred Android low-memory trimming safely on the main thread.
	trim := false
	sync.mutex_lock(&gamepad_state.lock)
	if gamepad_state.low_memory_flag {
		gamepad_state.low_memory_flag = false
		trim = true
	}
	sync.mutex_unlock(&gamepad_state.lock)
	if trim {
		interiors_trim_cache()
	}
}

// Filter out synthetic mouse events generated from touchscreen input.
@(private = "file")
input_event_filter :: proc "c" (userdata: rawptr, ev: ^sdl.Event) -> c.int {
	if ev == nil {
		return 1
	}
	#partial switch ev.type {
	case .MOUSEBUTTONDOWN, .MOUSEBUTTONUP:
		if ev.button.which == sdl.TOUCH_MOUSEID {
			return 0
		}
	case .MOUSEMOTION:
		if ev.motion.which == sdl.TOUCH_MOUSEID {
			return 0
		}
	case .MOUSEWHEEL:
		if ev.wheel.which == sdl.TOUCH_MOUSEID {
			return 0
		}
	}
	return 1
}

// Immediate event observer: processes touch fingers, generic joysticks, quick
// button taps, and Android lifecycle notifications as soon as SDL receives them.
@(private = "file")
input_event_watch :: proc "c" (userdata: rawptr, ev: ^sdl.Event) -> c.int {
	if ev == nil {
		return 1
	}
	context = runtime.default_context()
	#partial switch ev.type {
	case .FINGERDOWN, .FINGERMOTION, .FINGERUP:
		sync.mutex_lock(&gamepad_state.lock)
		gamepad_state.gamepad_active = false
		touch_handle_finger_locked(ev.tfinger)
		sync.mutex_unlock(&gamepad_state.lock)
		if ev.type == .FINGERDOWN {
			core.device_used(.PlayStation)
		}

	case .CONTROLLERDEVICEADDED:
		sync.mutex_lock(&gamepad_state.lock)
		gamepad_state.gamepad_active = true
		sync.mutex_unlock(&gamepad_state.lock)

	case .CONTROLLERBUTTONDOWN:
		bit := sdl_gc_button_to_pad_bit(sdl.GameControllerButton(ev.cbutton.button))
		sync.mutex_lock(&gamepad_state.lock)
		gamepad_state.gamepad_active = true
		gamepad_state.watch_pad_press |= bit
		sync.mutex_unlock(&gamepad_state.lock)

	case .CONTROLLERAXISMOTION:
		if abs(i32(ev.caxis.value)) >= 12000 {
			sync.mutex_lock(&gamepad_state.lock)
			gamepad_state.gamepad_active = true
			sync.mutex_unlock(&gamepad_state.lock)
		}

	case .JOYDEVICEADDED:
		gamepad_try_attach(ev.jdevice.which)

	case .JOYDEVICEREMOVED:
		gamepad_remove_generic(ev.jdevice.which)

	case .JOYBUTTONDOWN:
		sync.mutex_lock(&gamepad_state.lock)
		if g := find_generic_by_id_locked(ev.jbutton.which); g != nil {
			gamepad_state.gamepad_active = true
			gamepad_state.watch_pad_press |= generic_button_to_pad_bit(g, c.int(ev.jbutton.button))
		}
		sync.mutex_unlock(&gamepad_state.lock)

	case .JOYHATMOTION:
		if ev.jhat.value != sdl.HAT_CENTERED {
			sync.mutex_lock(&gamepad_state.lock)
			if find_generic_by_id_locked(ev.jhat.which) != nil {
				gamepad_state.gamepad_active = true
				gamepad_state.watch_pad_press |= hat_to_pad_bits(ev.jhat.value)
			}
			sync.mutex_unlock(&gamepad_state.lock)
		}

	case .JOYAXISMOTION:
		if abs(i32(ev.jaxis.value)) >= 14000 {
			sync.mutex_lock(&gamepad_state.lock)
			if find_generic_by_id_locked(ev.jaxis.which) != nil {
				gamepad_state.gamepad_active = true
			}
			sync.mutex_unlock(&gamepad_state.lock)
		}

	case .KEYDOWN:
		// Android hardware Back button (SDL_SCANCODE_AC_BACK) toggles pause
		// cleanly instead of leaving the app or getting swallowed.
		when ODIN_PLATFORM_SUBTARGET == .Android {
			if ev.key.keysym.scancode == .AC_BACK && ev.key.repeat == 0 {
				touch_toggle_pause()
			}
		}

	case .APP_WILLENTERBACKGROUND, .APP_DIDENTERBACKGROUND:
		// Release all virtual fingers & latches so nothing sticks when resuming.
		sync.mutex_lock(&gamepad_state.lock)
		touch_clear_fingers_locked()
		gamepad_state.pad_latch = {}
		gamepad_state.touch_latch = {}
		gamepad_state.watch_pad_press = 0
		sync.mutex_unlock(&gamepad_state.lock)

	case .APP_LOWMEMORY:
		sync.mutex_lock(&gamepad_state.lock)
		gamepad_state.low_memory_flag = true
		sync.mutex_unlock(&gamepad_state.lock)
	}
	return 1
}

// Attach a device index either to ps-recomp's SDL_GameController pool or to
// our generic SDL_Joystick fallback (ignoring non-gamepad sensors).
@(private = "file")
gamepad_try_attach :: proc(index: c.int) {
	if index < 0 {
		return
	}
	if sdl.IsGameController(index) {
		// Ensure core.input opens it (idempotent: deduplicated by instance ID).
		ev := sdl.Event {
			cdevice = {
				type  = .CONTROLLERDEVICEADDED,
				which = index,
			},
		}
		core.input_event(ev)
		return
	}
	name_c := sdl.JoystickNameForIndex(index)
	name := name_c != nil ? string(name_c) : ""
	if is_sensor_device_name(name) {
		return
	}
	sync.mutex_lock(&gamepad_state.lock)
	defer sync.mutex_unlock(&gamepad_state.lock)

	dev_id := sdl.JoystickGetDeviceInstanceID(index)
	for g in gamepad_state.generic {
		if g.joy != nil && g.id == dev_id {
			return
		}
	}
	joy := sdl.JoystickOpen(index)
	if joy == nil {
		return
	}
	nb := sdl.JoystickNumButtons(joy)
	na := sdl.JoystickNumAxes(joy)
	nh := sdl.JoystickNumHats(joy)
	if nb < MIN_GAMEPAD_BUTTONS && nh == 0 {
		sdl.JoystickClose(joy)
		return
	}
	for &slot in gamepad_state.generic {
		if slot.joy != nil {
			continue
		}
		l2_bi, r2_bi := false, false
		init_val: i16
		if na > 4 && sdl.JoystickGetAxisInitialState(joy, 4, &init_val) && init_val < -8000 {
			l2_bi = true
		}
		if na > 5 && sdl.JoystickGetAxisInitialState(joy, 5, &init_val) && init_val < -8000 {
			r2_bi = true
		}
		android_layout := ODIN_PLATFORM_SUBTARGET == .Android
		slot = Generic_Joy {
			joy               = joy,
			id                = sdl.JoystickInstanceID(joy),
			num_buttons       = nb,
			num_axes          = na,
			num_hats          = nh,
			l2_bipolar        = l2_bi,
			r2_bipolar        = r2_bi,
			is_android_layout = android_layout,
		}
		gamepad_state.gamepad_active = true
		fmt.eprintfln("gamepad: generic joystick fallback attached: %s (%d btns, %d axes, %d hats)", name, nb, na, nh)
		return
	}
	sdl.JoystickClose(joy)
}

@(private = "file")
gamepad_remove_generic :: proc(id: sdl.JoystickID) {
	sync.mutex_lock(&gamepad_state.lock)
	defer sync.mutex_unlock(&gamepad_state.lock)
	for &slot in gamepad_state.generic {
		if slot.joy != nil && slot.id == id {
			sdl.JoystickClose(slot.joy)
			slot = {}
		}
	}
}

@(private = "file")
find_generic_by_id_locked :: proc(id: sdl.JoystickID) -> ^Generic_Joy {
	for &slot in gamepad_state.generic {
		if slot.joy != nil && slot.id == id {
			return &slot
		}
	}
	return nil
}

// Reject accelerometers, gyroscopes, touchscreens, and vendor sensor nodes that
// Android/Linux kernels sometimes expose as joystick devices.
@(private)
is_sensor_device_name :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	low := strings.to_lower(name, context.temp_allocator)
	for bad in ([?]string{
		"accelerometer",
		"gyro",
		"sensor",
		"compass",
		"magnetometer",
		"fingerprint",
		"touchscreen",
		"motion sensor",
		"orientation",
	}) {
		if strings.contains(low, bad) {
			return true
		}
	}
	return false
}

// Radial deadzone with smooth linear rescaling [dz..1] -> [0..1].
// Preserves exact direction and sign: +x = right, +y = down.
@(private)
apply_radial_deadzone :: proc(v: [2]f32, dz: f32) -> [2]f32 {
	d := clamp(dz, 0.02, 0.70)
	m := math.sqrt(v.x * v.x + v.y * v.y)
	if m <= d {
		return {}
	}
	scaled := min((m - d) / (1.0 - d), 1.0)
	return v * (scaled / m)
}

// Normalize a trigger axis to 0..1, supporting both unipolar (0..32767) and
// bipolar (-32768..32767 resting at -32768) controllers automatically.
@(private)
normalize_trigger_axis :: proc(raw: i16, bipolar: ^bool) -> f32 {
	if raw < -8000 {
		bipolar^ = true
	}
	v := clamp(f32(raw) / 32767.0, -1.0, 1.0)
	if bipolar^ {
		return clamp((v + 1.0) * 0.5, 0.0, 1.0)
	}
	return clamp(v, 0.0, 1.0)
}

// Apply threshold + hysteresis so triggers feel snappy without chattering.
@(private)
trigger_pressed :: proc(value: f32, threshold: f32, was_held: ^bool) -> bool {
	th := clamp(threshold, 0.08, 0.90)
	rel := max(th - TRIGGER_HYSTERESIS, 0.03)
	if was_held^ {
		if value < rel {
			was_held^ = false
		}
	} else {
		if value >= th {
			was_held^ = true
		}
	}
	return was_held^
}

// Advance a Button_Latch by one game pad poll:
// - Newly pressed bits get latched for TAP_LATCH_POLLS polls.
// - Bits still held keep output high; their latch counters still count down
//   so releasing a long-held button happens immediately on the next poll!
// - Ultra-quick taps released before the game polled still stay asserted for
//   the remaining latch polls, guaranteeing zero dropped taps.
@(private)
latch_consume :: proc(l: ^Button_Latch, live: u16, extra_edge: u16) -> (out: u16) {
	rising := (live & ~l.prev_live) | extra_edge
	l.prev_live = live
	out = live
	for i in uint(0) ..< 16 {
		bit := u16(1) << i
		if rising & bit != 0 {
			l.polls_left[i] = TAP_LATCH_POLLS
		}
		if l.polls_left[i] > 0 {
			out |= bit
			l.polls_left[i] -= 1
		}
	}
	return out
}

// Convert SDL hat bitmask into exact PS1 PAD_* D-pad bits (supports 8-way).
@(private)
hat_to_pad_bits :: proc(hat: u8) -> (bits: u16) {
	if hat & sdl.HAT_UP != 0    { bits |= host.PAD_UP }
	if hat & sdl.HAT_RIGHT != 0 { bits |= host.PAD_RIGHT }
	if hat & sdl.HAT_DOWN != 0  { bits |= host.PAD_DOWN }
	if hat & sdl.HAT_LEFT != 0  { bits |= host.PAD_LEFT }
	return bits
}

// Convert an SDL_GameControllerButton (using core.input.buttons bindings)
// into the game's PAD_* bitmask for quick-tap latching.
@(private = "file")
sdl_gc_button_to_pad_bit :: proc(b: sdl.GameControllerButton) -> u16 {
	if int(b) < 0 || int(b) >= len(core.input.buttons) {
		return 0
	}
	return core_buttons_to_pad_mask(core.input.buttons[b])
}

// Convert ps:core wire-order Buttons to psx_host PAD_* high/low byte layout.
@(private)
core_buttons_to_pad_mask :: proc(b: core.Buttons) -> u16 {
	v := transmute(u16)b
	return (v << 8) | (v >> 8)
}

// Map a raw SDL_Joystick button index to a PS1 PAD_* bit.
@(private = "file")
generic_button_to_pad_bit :: proc(g: ^Generic_Joy, btn: c.int) -> u16 {
	if g.is_android_layout {
		// Standard Android SDL_Joystick button layout (SDLControllerManager):
		// 0:A(South/Cross) 1:B(East/Circle) 2:X(West/Square) 3:Y(North/Triangle)
		// 4:Back(Select) 5:Guide 6:Start 7:L3 8:R3 9:L1 10:R1
		// 11:Up 12:Down 13:Left 14:Right 15:L2 16:R2
		switch btn {
		case 0:  return host.PAD_CROSS
		case 1:  return host.PAD_CIRCLE
		case 2:  return host.PAD_SQUARE
		case 3:  return host.PAD_TRIANGLE
		case 4:  return host.PAD_SELECT
		case 6:  return host.PAD_START
		case 9:  return host.PAD_L1
		case 10: return host.PAD_R1
		case 11: return host.PAD_UP
		case 12: return host.PAD_DOWN
		case 13: return host.PAD_LEFT
		case 14: return host.PAD_RIGHT
		case 15: return host.PAD_L2
		case 16: return host.PAD_R2
		}
		return 0
	}
	// Standard generic Linux/USB HID gamepad layout:
	// 0:South(Cross) 1:East(Circle) 2:West(Square) 3:North(Triangle)
	// 4:L1 5:R1 6:L2/Select 7:R2/Start 8:Select 9:Start
	switch btn {
	case 0: return host.PAD_CROSS
	case 1: return host.PAD_CIRCLE
	case 2: return host.PAD_SQUARE
	case 3: return host.PAD_TRIANGLE
	case 4: return host.PAD_L1
	case 5: return host.PAD_R1
	case 6: return g.num_buttons >= 10 ? host.PAD_L2 : host.PAD_SELECT
	case 7: return g.num_buttons >= 10 ? host.PAD_R2 : host.PAD_START
	case 8: return host.PAD_SELECT
	case 9: return host.PAD_START
	}
	return 0
}

// Sample all active generic fallback joysticks (buttons + hat + sticks + triggers).
@(private = "file")
sample_generic_joys_locked :: proc() -> (held: u16, left, right: [2]f32) {
	dz := f32(config.pad_deadzone)
	th := f32(config.pad_trigger_threshold)
	for &g in gamepad_state.generic {
		if g.joy == nil {
			continue
		}
		for b: c.int = 0; b < g.num_buttons && b < 20; b += 1 {
			if sdl.JoystickGetButton(g.joy, b) != 0 {
				held |= generic_button_to_pad_bit(&g, b)
			}
		}
		if g.num_hats > 0 {
			held |= hat_to_pad_bits(sdl.JoystickGetHat(g.joy, 0))
		}
		if g.num_axes >= 2 {
			lx := clamp(f32(i16(sdl.JoystickGetAxis(g.joy, 0))) / 32767.0, -1.0, 1.0)
			ly := clamp(f32(i16(sdl.JoystickGetAxis(g.joy, 1))) / 32767.0, -1.0, 1.0)
			left = core.stronger(left, apply_radial_deadzone({lx, ly}, dz))
		}
		if g.num_axes >= 4 {
			rx := clamp(f32(i16(sdl.JoystickGetAxis(g.joy, 2))) / 32767.0, -1.0, 1.0)
			ry := clamp(f32(i16(sdl.JoystickGetAxis(g.joy, 3))) / 32767.0, -1.0, 1.0)
			right = core.stronger(right, apply_radial_deadzone({rx, ry}, dz))
		}
		if g.num_axes >= 5 {
			lt := normalize_trigger_axis(i16(sdl.JoystickGetAxis(g.joy, 4)), &g.l2_bipolar)
			if trigger_pressed(lt, th, &g.l2_pressed) {
				held |= host.PAD_L2
			}
		}
		if g.num_axes >= 6 {
			rt := normalize_trigger_axis(i16(sdl.JoystickGetAxis(g.joy, 5)), &g.r2_bipolar)
			if trigger_pressed(rt, th, &g.r2_pressed) {
				held |= host.PAD_R2
			}
		}
	}
	return
}

// Sample SDL_GameController triggers with the user's snappy lower threshold
// (core/input.odin hardcodes 0.50; this responds at config.pad_trigger_threshold).
@(private = "file")
sample_gc_triggers_locked :: proc() -> (held: u16) {
	th := f32(config.pad_trigger_threshold)
	max_l, max_r: f32
	for pad in core.input.pads {
		if pad == nil {
			continue
		}
		l := clamp(f32(sdl.GameControllerGetAxis(pad, .TRIGGERLEFT)) / 32767.0, 0.0, 1.0)
		r := clamp(f32(sdl.GameControllerGetAxis(pad, .TRIGGERRIGHT)) / 32767.0, 0.0, 1.0)
		if l > max_l { max_l = l }
		if r > max_r { max_r = r }
	}
	if trigger_pressed(max_l, th, &gamepad_state.gc_l2_held) {
		held |= core_buttons_to_pad_mask(core.input.triggers[.Left])
	}
	if trigger_pressed(max_r, th, &gamepad_state.gc_r2_held) {
		held |= core_buttons_to_pad_mask(core.input.triggers[.Right])
	}
	return held
}

// Refresh SDL controller & joystick state at most once per emulated vblank so
// button presses and stick movements are sampled with minimum latency.
@(private = "file")
input_pump_live :: proc() {
	if core.headless || io.preload_child || !gamepad_state.initialized {
		return
	}
	v := cpu.vblanks()
	if v == gamepad_state.last_pump_vblank {
		return
	}
	gamepad_state.last_pump_vblank = v
	sdl.PumpEvents()
	sdl.GameControllerUpdate()
	sdl.JoystickUpdate()
}

// Swap PAD_CROSS <-> PAD_CIRCLE when user enables [pad] swap_confirm.
@(private)
apply_confirm_swap :: proc(held: u16, swap: bool) -> u16 {
	if !swap {
		return held
	}
	cross := held & host.PAD_CROSS != 0
	circle := held & host.PAD_CIRCLE != 0
	out := held & ~(host.PAD_CROSS | host.PAD_CIRCLE)
	if cross  { out |= host.PAD_CIRCLE }
	if circle { out |= host.PAD_CROSS }
	return out
}

// Convert an analog stick vector (+x right, +y down) into 8-way PS1 D-pad bits.
// Uses the exact same clockwise-from-up convention as host.STICK_SECTORS.
@(private)
stick_to_dpad_bits :: proc(v: [2]f32) -> u16 {
	if v == {} {
		return 0
	}
	sector := int(math.round(core.stick_angle(v) / 45.0)) & 7
	return host.STICK_SECTORS[sector]
}

// Unified analog sticks (+x right, +y down, in -1..1 after radial deadzone):
// merges SDL GameController (with configurable deadzone), replay/script/autoplay,
// generic fallback joysticks, and virtual touch Left & Right analog sticks.
@(private)
input_sticks :: proc() -> (s: host.Sticks) {
	if io.preload_child {
		return
	}
	// Preserve 100% stock behavior in headless regression tests.
	if core.headless {
		return host.sticks()
	}
	input_pump_live()

	// Start with stock host.sticks() (captures replay, autoplay, stick_script,
	// and sticks_left_blocked).
	s = host.sticks()

	// Apply configurable deadzone directly on raw SDL_GameController axes when
	// user lowers deadzone below ps-recomp's hardcoded 0.20 (or raises it).
	dz := f32(config.pad_deadzone)
	raw_gc_l, raw_gc_r: [2]f32
	for pad in core.input.pads {
		if pad == nil {
			continue
		}
		l := [2]f32{
			clamp(f32(sdl.GameControllerGetAxis(pad, .LEFTX)) / 32767.0, -1.0, 1.0),
			clamp(f32(sdl.GameControllerGetAxis(pad, .LEFTY)) / 32767.0, -1.0, 1.0),
		}
		r := [2]f32{
			clamp(f32(sdl.GameControllerGetAxis(pad, .RIGHTX)) / 32767.0, -1.0, 1.0),
			clamp(f32(sdl.GameControllerGetAxis(pad, .RIGHTY)) / 32767.0, -1.0, 1.0),
		}
		raw_gc_l = core.stronger(raw_gc_l, l)
		raw_gc_r = core.stronger(raw_gc_r, r)
	}
	gc_l := apply_radial_deadzone(raw_gc_l, dz)
	gc_r := apply_radial_deadzone(raw_gc_r, dz)
	if !host.sticks_left_blocked {
		if dz > core.STICK_DEADZONE {
			// User asked for a wider deadzone to suppress stick drift: zero out
			// small controller drift that host.sticks() let through unless
			// autoplay/script/replay drove it.
			if gc_l == {} && host.auto_stick == {} && s.left != {} && raw_gc_l != {} {
				s.left = {}
			}
		} else {
			s.left = core.stronger(s.left, gc_l)
		}
	}
	if dz > core.STICK_DEADZONE {
		if gc_r == {} && s.right != {} && raw_gc_r != {} {
			s.right = {}
		}
	} else {
		s.right = core.stronger(s.right, gc_r)
	}

	sync.mutex_lock(&gamepad_state.lock)
	_, gen_l, gen_r := sample_generic_joys_locked()
	touch_l, touch_r := touch_sticks_locked()
	sync.mutex_unlock(&gamepad_state.lock)

	if !host.sticks_left_blocked {
		s.left = core.stronger(s.left, gen_l)
		s.left = core.stronger(s.left, touch_l)
	}
	s.right = core.stronger(s.right, gen_r)
	s.right = core.stronger(s.right, touch_r)

	// Optional X-axis camera inversion on right stick (additive with in-game Camera setting).
	if config.pad_invert_camera_x {
		s.right.x = -s.right.x
	}
	return s
}

// Unified pad hook chained into host.pad_hook: merges snappy GameController
// triggers, generic fallback joysticks, PS1 touch controls, left-stick-to-dpad,
// 2-poll quick-tap latch, and optional Cross/Circle swap.
@(private = "file")
input_pad_hook :: proc(held: u16) -> u16 {
	out := held
	if !core.headless && !io.preload_child {
		input_pump_live()

		sync.mutex_lock(&gamepad_state.lock)
		gc_trigs := sample_gc_triggers_locked()
		gen_held, gen_l, _ := sample_generic_joys_locked()
		touch_live, touch_edge := touch_consume_buttons_locked()
		touch_l, _ := touch_sticks_locked()
		watch_edge := gamepad_state.watch_pad_press
		gamepad_state.watch_pad_press = 0

		// Physical controller buttons (including snappy triggers & generic fallback)
		phys_live := out | gc_trigs | gen_held
		phys_out := latch_consume(&gamepad_state.pad_latch, phys_live, watch_edge)

		// Touch controller buttons (D-pad, face buttons, shoulders, Start/Select)
		touch_out := latch_consume(&gamepad_state.touch_latch, touch_live, touch_edge)
		sync.mutex_unlock(&gamepad_state.lock)

		out = phys_out | touch_out

		// Drive D-pad from generic joystick & touch left analog sticks (so all
		// PS1 menus work smoothly with virtual or generic left sticks too!).
		if !host.sticks_left_blocked {
			if gen_l != {} {
				out |= stick_to_dpad_bits(gen_l)
			}
			if touch_l != {} {
				out |= stick_to_dpad_bits(touch_l)
			}
		}

		out = apply_confirm_swap(out, config.pad_swap_confirm)
	}

	// Preserve downstream hooks (e.g. mouse_menus).
	if gamepad_state.prev_pad_hook != nil {
		out = gamepad_state.prev_pad_hook(out)
	}
	return out
}

// Route DualShock rumble to both SDL GameControllers and generic fallback joysticks.
@(private = "file")
input_pad_rumble :: proc(small: bool, large: u8) {
	host.pad_rumble(small, large)
	if core.headless || config.pad_rumble <= 0 {
		return
	}
	scale := f32(clamp(config.pad_rumble, 0, 1))
	low := u16(f32(large) * (65535.0 / 255.0) * scale)
	high := small ? u16(65535.0 * scale) : u16(0)
	sync.mutex_lock(&gamepad_state.lock)
	for g in gamepad_state.generic {
		if g.joy != nil {
			sdl.JoystickRumble(g.joy, low, high, 500)
		}
	}
	sync.mutex_unlock(&gamepad_state.lock)
}

// Register an additional pad_hook (used by mouse_menus so it never overwrites
// gamepad/touch input!).
@(private)
input_chain_pad_hook :: proc(hook: proc(held: u16) -> u16) {
	if host.pad_hook == input_pad_hook {
		gamepad_state.prev_pad_hook = hook
	} else {
		host.pad_hook = hook
	}
}
