// In-game Quick Settings Menu + floating MENU button overlay.
//
// Accessible via:
//   - On-screen top-right MENU button (touch or mouse click)
//   - Gamepad L3 + R3 combo
//   - Android hardware Back button (AC_BACK)
//   - Keyboard F1 (desktop)
//
// Allows live editing of Resolution (1x/2x/4x), FPS Limit (30/60/90/120/Unlimited),
// Graphics API (OpenGL ES / OpenGL / Vulkan), Anti-Wobble (PGXP), Texture Filter,
// Soft Texels, Scaling, Audio Smooth Fix / Latency / Volume, Touch & Pad Controls,
// and Mods / Texture Packs / Live Texture Dumping — persisted straight to bof4.ini.
package qol

import "core:c"
import "core:fmt"
import "core:math"
import "core:sync"
import sdl "vendor:sdl2"

import "ps:core"
import host "ps:psx/host"
import render "ps:psx/render"

@(private)
Renderer_Backend :: enum u8 {
	OpenGL, // Software rasterizer presented via OpenGL ES 2 (Android) / OpenGL (Desktop)
	Vulkan, // Vulkan 1.3 hardware hi-res rasterizer
	Auto,   // Platform default (OpenGL ES on Android, Vulkan on Desktop)
}

@(private)
RENDERER_BACKEND_KEYS := [Renderer_Backend]string {
	.OpenGL = "opengl",
	.Vulkan = "vulkan",
	.Auto   = "auto",
}

@(private)
Quick_Tab :: enum u8 {
	Video,
	Audio,
	Controls,
	Mods,
}

@(private)
QUICK_TAB_LABELS := [Quick_Tab]string {
	.Video    = "VIDEO",
	.Audio    = "AUDIO",
	.Controls = "CONTROLS",
	.Mods     = "MODS",
}

@(private = "file")
Menu_Action_Kind :: enum u8 {
	None,
	Toggle_Open,
	Close,
	Select_Tab,
	Move_Cursor,
	Step_Row,
	Tap_Screen,
}

@(private = "file")
Menu_Action :: struct {
	kind: Menu_Action_Kind,
	arg:  int,
	x, y: f32,
}

@(private = "file")
MAX_QUEUED_ACTIONS :: 16

@(private = "file")
Quick_Rect :: struct {
	x, y, w, h: f32,
}

@(private = "file")
quick_menu: struct {
	lock:       sync.Mutex,
	open:       bool,
	tab:        Quick_Tab,
	cursor:     int,
	scroll:     int,
	// Cached screen geometry (updated on every render frame).
	screen_w:   f32,
	screen_h:   f32,
	btn_rect:   Quick_Rect,
	panel_rect: Quick_Rect,
	close_rect: Quick_Rect,
	tab_rects:  [Quick_Tab]Quick_Rect,
	row_rects:  [12]Quick_Rect,
	row_count:  int,
	// Pending actions queued from SDL event watch, executed safely on main thread.
	queue:      [MAX_QUEUED_ACTIONS]Menu_Action,
	qlen:       int,
	// Font atlas texture (128x64, 16x6 grid of 8x8 ASCII 32..126 glyphs).
	font_tex:   ^sdl.Texture,
	font_r:     ^sdl.Renderer,
	// Gamepad L3+R3 edge tracking.
	l3_held:    bool,
	r3_held:    bool,
	combo_used: bool,
	// Brief status banner inside panel (e.g. "Saved to bof4.ini").
	note:       string,
	note_until: u32,
}

@(private)
quick_menu_is_open :: proc() -> bool {
	sync.mutex_lock(&quick_menu.lock)
	v := quick_menu.open
	sync.mutex_unlock(&quick_menu.lock)
	return v
}

@(private)
quick_menu_toggle :: proc() {
	sync.mutex_lock(&quick_menu.lock)
	quick_menu_push_locked({kind = .Toggle_Open})
	sync.mutex_unlock(&quick_menu.lock)
}

@(private = "file")
quick_menu_push_locked :: proc(a: Menu_Action) {
	if quick_menu.qlen < MAX_QUEUED_ACTIONS {
		quick_menu.queue[quick_menu.qlen] = a
		quick_menu.qlen += 1
	}
}

// Intercept touch events for the MENU button and open overlay panel.
// Returns true if the quick menu consumed this finger event.
@(private)
quick_menu_handle_finger :: proc(ev: sdl.TouchFingerEvent) -> bool {
	sync.mutex_lock(&quick_menu.lock)
	defer sync.mutex_unlock(&quick_menu.lock)

	w := quick_menu.screen_w > 0 ? quick_menu.screen_w : touch_state.layout.w
	h := quick_menu.screen_h > 0 ? quick_menu.screen_h : touch_state.layout.h
	if w <= 0 || h <= 0 {
		return false
	}
	px := ev.x * w
	py := ev.y * h

	if !quick_menu.open {
		if ev.type == .FINGERDOWN && rect_hit(quick_menu.btn_rect, px, py) {
			quick_menu_push_locked({kind = .Toggle_Open})
			return true
		}
		return false
	}

	// Menu is open: consume ALL touch events so the game never receives them.
	if ev.type == .FINGERDOWN {
		quick_menu_push_locked({kind = .Tap_Screen, x = px, y = py})
	}
	return true
}

// Intercept mouse clicks for the MENU button & panel on desktop.
@(private)
quick_menu_handle_mouse :: proc(ev: sdl.MouseButtonEvent) -> bool {
	sync.mutex_lock(&quick_menu.lock)
	defer sync.mutex_unlock(&quick_menu.lock)

	// Map window coordinates to renderer output pixel coordinates.
	px, py := f32(ev.x), f32(ev.y)
	if !quick_menu.open {
		if ev.type == .MOUSEBUTTONDOWN && ev.button == sdl.BUTTON_LEFT && rect_hit(quick_menu.btn_rect, px, py) {
			quick_menu_push_locked({kind = .Toggle_Open})
			return true
		}
		return false
	}
	if ev.type == .MOUSEBUTTONDOWN && ev.button == sdl.BUTTON_LEFT {
		quick_menu_push_locked({kind = .Tap_Screen, x = px, y = py})
	}
	return true
}

// Intercept keyboard keys (F1 toggles; arrows/Enter/Esc navigate while open).
@(private)
quick_menu_handle_key :: proc(ev: sdl.KeyboardEvent) -> bool {
	if ev.type != .KEYDOWN || ev.repeat != 0 {
		return quick_menu_is_open()
	}
	sc := ev.keysym.scancode
	if sc == .F1 {
		quick_menu_toggle()
		return true
	}
	when ODIN_PLATFORM_SUBTARGET == .Android {
		if sc == .AC_BACK {
			quick_menu_toggle()
			return true
		}
	}
	sync.mutex_lock(&quick_menu.lock)
	defer sync.mutex_unlock(&quick_menu.lock)
	if !quick_menu.open {
		return false
	}
	#partial switch sc {
	case .ESCAPE, .BACKSPACE:
		quick_menu_push_locked({kind = .Close})
	case .UP, .W:
		quick_menu_push_locked({kind = .Move_Cursor, arg = -1})
	case .DOWN, .S:
		quick_menu_push_locked({kind = .Move_Cursor, arg = 1})
	case .LEFT, .A:
		quick_menu_push_locked({kind = .Step_Row, arg = -1})
	case .RIGHT, .D, .RETURN, .SPACE:
		quick_menu_push_locked({kind = .Step_Row, arg = 1})
	case .TAB:
		next_tab := (int(quick_menu.tab) + 1) % len(Quick_Tab)
		quick_menu_push_locked({kind = .Select_Tab, arg = next_tab})
	}
	return true
}

// Intercept gamepad buttons (L3+R3 toggles; D-pad/A/B/L1/R1 navigate while open).
@(private)
quick_menu_handle_controller :: proc(ev: sdl.ControllerButtonEvent) -> bool {
	btn := sdl.GameControllerButton(ev.button)
	down := ev.type == .CONTROLLERBUTTONDOWN

	sync.mutex_lock(&quick_menu.lock)
	defer sync.mutex_unlock(&quick_menu.lock)

	if btn == .LEFTSTICK {
		quick_menu.l3_held = down
	} else if btn == .RIGHTSTICK {
		quick_menu.r3_held = down
	}
	if quick_menu.l3_held && quick_menu.r3_held {
		if !quick_menu.combo_used {
			quick_menu.combo_used = true
			quick_menu_push_locked({kind = .Toggle_Open})
		}
		return true
	} else {
		quick_menu.combo_used = false
	}

	if !quick_menu.open {
		return false
	}
	if !down {
		return true
	}
	#partial switch btn {
	case .B, .BACK:
		quick_menu_push_locked({kind = .Close})
	case .DPAD_UP:
		quick_menu_push_locked({kind = .Move_Cursor, arg = -1})
	case .DPAD_DOWN:
		quick_menu_push_locked({kind = .Move_Cursor, arg = 1})
	case .DPAD_LEFT:
		quick_menu_push_locked({kind = .Step_Row, arg = -1})
	case .DPAD_RIGHT, .A:
		quick_menu_push_locked({kind = .Step_Row, arg = 1})
	case .LEFTSHOULDER:
		prev := (int(quick_menu.tab) + len(Quick_Tab) - 1) % len(Quick_Tab)
		quick_menu_push_locked({kind = .Select_Tab, arg = prev})
	case .RIGHTSHOULDER:
		next := (int(quick_menu.tab) + 1) % len(Quick_Tab)
		quick_menu_push_locked({kind = .Select_Tab, arg = next})
	}
	return true
}

// Drain queued menu actions safely on the main emulation thread.
@(private)
quick_menu_vblank :: proc() {
	actions: [MAX_QUEUED_ACTIONS]Menu_Action
	n := 0
	sync.mutex_lock(&quick_menu.lock)
	n = quick_menu.qlen
	if n > 0 {
		copy(actions[:n], quick_menu.queue[:n])
		quick_menu.qlen = 0
	}
	sync.mutex_unlock(&quick_menu.lock)

	for i in 0 ..< n {
		execute_menu_action(actions[i])
	}
}

@(private = "file")
execute_menu_action :: proc(a: Menu_Action) {
	switch a.kind {
	case .None:
	case .Toggle_Open:
		sync.mutex_lock(&quick_menu.lock)
		quick_menu.open = !quick_menu.open
		quick_menu.cursor = 0
		quick_menu.scroll = 0
		is_open := quick_menu.open
		sync.mutex_unlock(&quick_menu.lock)
		if is_open {
			// Clear any held virtual touch fingers so nothing sticks while menu is open.
			sync.mutex_lock(&gamepad_state.lock)
			touch_clear_fingers_locked()
			sync.mutex_unlock(&gamepad_state.lock)
		}
	case .Close:
		sync.mutex_lock(&quick_menu.lock)
		quick_menu.open = false
		sync.mutex_unlock(&quick_menu.lock)
	case .Select_Tab:
		if a.arg >= 0 && a.arg < len(Quick_Tab) {
			sync.mutex_lock(&quick_menu.lock)
			quick_menu.tab = Quick_Tab(a.arg)
			quick_menu.cursor = 0
			quick_menu.scroll = 0
			sync.mutex_unlock(&quick_menu.lock)
		}
	case .Move_Cursor:
		total := tab_row_count(quick_menu.tab)
		if total > 0 {
			sync.mutex_lock(&quick_menu.lock)
			quick_menu.cursor = (quick_menu.cursor + a.arg + total) % total
			sync.mutex_unlock(&quick_menu.lock)
		}
	case .Step_Row:
		apply_tab_row_step(quick_menu.tab, quick_menu.cursor, a.arg)
	case .Tap_Screen:
		handle_menu_tap(a.x, a.y)
	}
}

@(private = "file")
handle_menu_tap :: proc(px, py: f32) {
	if rect_hit(quick_menu.close_rect, px, py) || !rect_hit(quick_menu.panel_rect, px, py) {
		sync.mutex_lock(&quick_menu.lock)
		quick_menu.open = false
		sync.mutex_unlock(&quick_menu.lock)
		return
	}
	for t in Quick_Tab {
		if rect_hit(quick_menu.tab_rects[t], px, py) {
			sync.mutex_lock(&quick_menu.lock)
			quick_menu.tab = t
			quick_menu.cursor = 0
			quick_menu.scroll = 0
			sync.mutex_unlock(&quick_menu.lock)
			return
		}
	}
	for i in 0 ..< quick_menu.row_count {
		r := quick_menu.row_rects[i]
		if rect_hit(r, px, py) {
			row_idx := quick_menu.scroll + i
			sync.mutex_lock(&quick_menu.lock)
			quick_menu.cursor = row_idx
			sync.mutex_unlock(&quick_menu.lock)
			// Tap left half of the value area to decrement, right half (or label) to increment/toggle.
			val_mid := r.x + r.w * 0.72
			dir := (px > r.x + r.w * 0.50 && px < val_mid) ? -1 : 1
			apply_tab_row_step(quick_menu.tab, row_idx, dir)
			return
		}
	}
}

@(private = "file")
tab_row_count :: proc(tab: Quick_Tab) -> int {
	switch tab {
	case .Video:    return 8
	case .Audio:    return 3
	case .Controls: return 6
	case .Mods:
		when ODIN_PLATFORM_SUBTARGET == .Android {
			return 5 + min(len(mods_state.mods), 7)
		} else {
			return 4 + min(len(mods_state.mods), 8)
		}
	}
	return 0
}

@(private = "file")
FPS_PRESETS := [5]int{30, 60, 90, 120, 0}

@(private = "file")
LATENCY_PRESETS := [8]int{40, 60, 90, 120, 140, 180, 240, 320}

@(private = "file")
set_menu_note :: proc(msg: string) {
	quick_menu.note = msg
	quick_menu.note_until = sdl.GetTicks() + 3000
}

@(private = "file")
apply_tab_row_step :: proc(tab: Quick_Tab, row, dir: int) {
	switch tab {
	case .Video:
		switch row {
		case 0: // Resolution / Detail (1x / 2x / 4x)
			n := (int(config.window.detail) + dir + 3) % 3
			config.window.detail = host.Detail(n)
			config_detail_explicit = true
			_ = host.window_apply(config.window)
			det_s := config.window.detail == .X1 ? "1" : (config.window.detail == .X2 ? "2" : "4")
			_ = config_write({{"window", "detail", det_s}})
			set_menu_note("Resolution updated")

		case 1: // FPS Limit (30 / 60 / 90 / 120 / Unlimited)
			idx := 1
			for p, k in FPS_PRESETS {
				if p == config.window_fps_limit {
					idx = k
					break
				}
			}
			idx = (idx + dir + len(FPS_PRESETS)) % len(FPS_PRESETS)
			config.window_fps_limit = FPS_PRESETS[idx]
			when PS_ANDROID_PATCH {
				host.set_fps_limit(i32(config.window_fps_limit))
			}
			_ = config_write({{"window", "fps_limit", fmt.tprintf("%d", config.window_fps_limit)}})
			set_menu_note("FPS limit updated")

		case 2: // Graphics API (OpenGL ES/OpenGL vs Vulkan)
			if config.window_backend == .Vulkan || (config.window_backend == .Auto && config.window_hardware) {
				config.window_backend = .OpenGL
				config.window_hardware = false
			} else {
				config.window_backend = .Vulkan
				config.window_hardware = true
			}
			config_hardware_explicit = true
			_ = config_write({
				{"window", "backend", RENDERER_BACKEND_KEYS[config.window_backend]},
				{"window", "hardware", config.window_hardware ? "true" : "false"},
			})
			set_menu_note("Restart app to switch Graphics API")

		case 3: // Anti-Wobble (PGXP subpixel + perspective correction)
			config.window_anti_wobble = !config.window_anti_wobble
			when PS_ANDROID_PATCH {
				render.anti_wobble = config.window_anti_wobble
			}
			_ = config_write({{"window", "anti_wobble", config.window_anti_wobble ? "true" : "false"}})
			set_menu_note(config.window_anti_wobble ? "Anti-Wobble PGXP ON" : "Anti-Wobble PGXP OFF")

		case 4: // Texture Presentation Filter (Linear / Nearest)
			config.window.filter = config.window.filter == .Linear ? .Nearest : .Linear
			config_filter_explicit = true
			_ = host.window_apply(config.window)
			_ = config_write({{"window", "filter", config.window.filter == .Linear ? "linear" : "nearest"}})
			set_menu_note("Screen filter updated")

		case 5: // Soft Texels (sharp-bilinear anti-shimmer at 2x/4x)
			config.window_smooth_textures = !config.window_smooth_textures
			config_smooth_tex_explicit = true
			render.smooth_textures = config.window_smooth_textures
			_ = config_write({{"window", "smooth_textures", config.window_smooth_textures ? "true" : "false"}})
			set_menu_note("Soft texels updated")

		case 6: // Scaling (Fit / Integer)
			config.window.scale = config.window.scale == .Fit ? .Integer : .Fit
			_ = host.window_apply(config.window)
			_ = config_write({{"window", "scale", config.window.scale == .Integer ? "integer" : "fit"}})
			set_menu_note("Scaling mode updated")

		case 7: // 60 FPS Motion Interpolation
			config.window_smooth_motion = !config.window_smooth_motion
			_ = config_write({{"window", "smooth_motion", config.window_smooth_motion ? "true" : "false"}})
			set_menu_note("Restart app for 60 FPS Motion")
		}

	case .Audio:
		switch row {
		case 0: // Audio Smooth Fix
			config.audio_smooth_fix = !config.audio_smooth_fix
			when PS_ANDROID_PATCH {
				core.audio_smooth_fix = config.audio_smooth_fix
			}
			_ = config_write({{"audio", "smooth_fix", config.audio_smooth_fix ? "true" : "false"}})
			set_menu_note(config.audio_smooth_fix ? "Audio smooth fix ON" : "Audio smooth fix OFF")

		case 1: // Audio Latency
			idx := 4
			best := 9999
			for p, k in LATENCY_PRESETS {
				if abs(p - config.audio_latency_ms) < best {
					best = abs(p - config.audio_latency_ms)
					idx = k
				}
			}
			idx = clamp(idx + dir, 0, len(LATENCY_PRESETS) - 1)
			config.audio_latency_ms = LATENCY_PRESETS[idx]
			config_audio_latency_explicit = true
			core.audio_apply(config.audio_latency_ms)
			_ = config_write({{"audio", "latency_ms", fmt.tprintf("%d", config.audio_latency_ms)}})
			set_menu_note("Audio buffer updated")

		case 2: // Master Volume (0% .. 100%)
			v := math.round(config.audio_volume * 10.0 + f64(dir)) / 10.0
			config.audio_volume = clamp(v, 0.0, 1.0)
			when PS_ANDROID_PATCH {
				core.audio_volume = f32(config.audio_volume)
			}
			_ = config_write({{"audio", "volume", fmt.tprintf("%.1f", config.audio_volume)}})
			set_menu_note("Volume updated")
		}

	case .Controls:
		switch row {
		case 0: // Touch Controls (Auto / On / Off)
			n := (int(config.touch_mode) + dir + 3) % 3
			config.touch_mode = Touch_Mode(n)
			_ = config_write({{"touch", "mode", TOUCH_MODE_KEYS[config.touch_mode]}})
			set_menu_note("Touch mode updated")

		case 1: // Touch Layout (DualShock / Digital / Analog)
			n := (int(config.touch_layout) + dir + 3) % 3
			config.touch_layout = Touch_Layout_Mode(n)
			_ = config_write({{"touch", "layout", TOUCH_LAYOUT_KEYS[config.touch_layout]}})
			set_menu_note("Touch layout updated")

		case 2: // Touch Opacity
			v := clamp(math.round(config.touch_opacity * 10.0 + f64(dir)) / 10.0, 0.2, 1.0)
			config.touch_opacity = v
			_ = config_write({{"touch", "opacity", fmt.tprintf("%.2f", config.touch_opacity)}})
			set_menu_note("Touch opacity updated")

		case 3: // Touch Scale
			v := clamp(math.round(config.touch_scale * 10.0 + f64(dir)) / 10.0, 0.7, 1.4)
			config.touch_scale = v
			_ = config_write({{"touch", "scale", fmt.tprintf("%.2f", config.touch_scale)}})
			set_menu_note("Touch scale updated")

		case 4: // Haptics / Vibration (0% .. 100%)
			v := clamp(math.round(config.pad_rumble * 5.0 + f64(dir)) / 5.0, 0.0, 1.0)
			config.pad_rumble = v
			gamepad_apply_config()
			_ = config_write({{"pad", "rumble", fmt.tprintf("%.2f", config.pad_rumble)}})
			set_menu_note("Vibration updated")

		case 5: // Stick Deadzone
			v := clamp(math.round(config.pad_deadzone * 20.0 + f64(dir)) / 20.0, 0.05, 0.30)
			config.pad_deadzone = v
			_ = config_write({{"pad", "deadzone", fmt.tprintf("%.2f", config.pad_deadzone)}})
			set_menu_note("Deadzone updated")
		}

	case .Mods:
		switch row {
		case 0: // Mods Enabled
			config.mods_enabled = !config.mods_enabled
			_ = config_write({{"mods", "enabled", config.mods_enabled ? "true" : "false"}})
			mods_reload()
			set_menu_note(config.mods_enabled ? "Mods enabled" : "Mods disabled")

		case 1: // Texture Packs
			config.mods_textures = !config.mods_textures
			_ = config_write({{"mods", "textures", config.mods_textures ? "true" : "false"}})
			mods_reload()
			set_menu_note(config.mods_textures ? "Texture packs ON" : "Texture packs OFF")

		case 2: // Dump Textures
			config.mods_dump_textures = !config.mods_dump_textures
			when PS_ANDROID_PATCH {
				render.mod_tex_dump = config.mods_dump_textures
			}
			_ = config_write({{"mods", "dump_textures", config.mods_dump_textures ? "true" : "false"}})
			set_menu_note(config.mods_dump_textures ? "Dumping PNGs to mods/dumped_textures/" : "Texture dump OFF")

		case 3: // Reload Mods
			mods_reload_with_toast()
			set_menu_note(fmt.tprintf("Reloaded: %d mods, %d tex", mods_state.active_mods, mods_state.loaded_tex))

		case:
			mod_idx := row - 4
			when ODIN_PLATFORM_SUBTARGET == .Android {
				if row == 4 {
					mods_request_android_setup()
					set_menu_note("Reopen app to use Import Mod (.zip)!")
					return
				}
				mod_idx = row - 5
			}
			if mods_toggle(mod_idx) {
				set_menu_note("Mod toggled & reloaded")
			}
		}
	}
}

@(private = "file")
row_label_value :: proc(tab: Quick_Tab, row: int) -> (label, value: string) {
	switch tab {
	case .Video:
		switch row {
		case 0:
			v := config.window.detail == .X1 ? "1x (320x240)" : (config.window.detail == .X2 ? "2x (640x480)" : "4x (1280x960)")
			return "Resolution", v
		case 1:
			v := config.window_fps_limit == 0 ? "Unlimited" : fmt.tprintf("%d FPS", config.window_fps_limit)
			return "FPS Limit", v
		case 2:
			is_vk := config.window_backend == .Vulkan || (config.window_backend == .Auto && config.window_hardware)
			when ODIN_PLATFORM_SUBTARGET == .Android {
				base := is_vk ? "Vulkan (GPU)" : "OpenGL ES (SW)"
			} else {
				base := is_vk ? "Vulkan (GPU)" : "OpenGL (SW)"
			}
			needs := config.window_hardware != config_boot.window_hardware
			return "Graphics API", needs ? fmt.tprintf("%s *", base) : base
		case 3:
			return "Anti-Wobble (PGXP)", config.window_anti_wobble ? "ON" : "OFF"
		case 4:
			return "Screen Filter", config.window.filter == .Linear ? "Linear (Smooth)" : "Nearest (Sharp)"
		case 5:
			return "Soft Texels", config.window_smooth_textures ? "ON" : "OFF"
		case 6:
			return "Scaling", config.window.scale == .Integer ? "Integer" : "Fit 4:3"
		case 7:
			needs := config.window_smooth_motion != config_boot.window_smooth_motion
			base := config.window_smooth_motion ? "ON" : "OFF"
			return "60 FPS Motion", needs ? fmt.tprintf("%s *", base) : base
		}

	case .Audio:
		switch row {
		case 0:
			return "Audio Smooth Fix", config.audio_smooth_fix ? "ON" : "OFF"
		case 1:
			return "Audio Latency", fmt.tprintf("%d ms", config.audio_latency_ms)
		case 2:
			return "Master Volume", fmt.tprintf("%d%%", int(math.round(config.audio_volume * 100.0)))
		}

	case .Controls:
		switch row {
		case 0:
			return "Touch Controls", TOUCH_MODE_TEXT[config.touch_mode]
		case 1:
			return "Touch Layout", TOUCH_LAYOUT_TEXT[config.touch_layout]
		case 2:
			return "Touch Opacity", fmt.tprintf("%d%%", int(math.round(config.touch_opacity * 100.0)))
		case 3:
			return "Touch Scale", fmt.tprintf("%d%%", int(math.round(config.touch_scale * 100.0)))
		case 4:
			if config.pad_rumble <= 0.01 {
				return "Vibration", "OFF"
			}
			return "Vibration", fmt.tprintf("%d%%", int(math.round(config.pad_rumble * 100.0)))
		case 5:
			return "Stick Deadzone", fmt.tprintf("%d%%", int(math.round(config.pad_deadzone * 100.0)))
		}

	case .Mods:
		switch row {
		case 0:
			return "Mods Enabled", config.mods_enabled ? "ON" : "OFF"
		case 1:
			return "Texture Packs", config.mods_textures ? "ON" : "OFF"
		case 2:
			return "Dump Textures", config.mods_dump_textures ? "ON" : "OFF"
		case 3:
			return "Reload All Mods", fmt.tprintf("[RELOAD] (%d)", len(mods_state.mods))
		case:
			idx := row - 4
			when ODIN_PLATFORM_SUBTARGET == .Android {
				if row == 4 {
					return "Mod Importer (.zip)", "[OPEN ON RESTART]"
				}
				idx = row - 5
			}
			if idx >= 0 && idx < len(mods_state.mods) {
				m := &mods_state.mods[idx]
				nm := len(m.name) > 22 ? m.name[:22] : m.name
				st := m.enabled ? fmt.tprintf("ON (%dp %dt)", m.patch_count, m.tex_count) : "OFF"
				return nm, st
			}
		}
	}
	return "", ""
}

// ---------------------------------------------------------------- SDL2 Rendering

// Draw the floating MENU button (always accessible) and the open Settings panel
// directly in physical screen coordinates. Called from touch_render_sdl().
@(private)
quick_menu_render_sdl :: proc(r: ^sdl.Renderer) {
	if r == nil {
		return
	}
	out_w, out_h: c.int
	if sdl.GetRendererOutputSize(r, &out_w, &out_h) != 0 || out_w <= 0 || out_h <= 0 {
		return
	}
	fw, fh := f32(out_w), f32(out_h)
	ensure_font_atlas(r)

	// Reset logical size temporarily so UI draws at native crisp screen DPI.
	prev_lw, prev_lh: c.int
	sdl.RenderGetLogicalSize(r, &prev_lw, &prev_lh)
	prev_int := sdl.RenderGetIntegerScale(r)
	sdl.RenderSetLogicalSize(r, 0, 0)
	sdl.RenderSetViewport(r, nil)
	sdl.RenderSetScale(r, 1, 1)
	defer if prev_lw > 0 && prev_lh > 0 {
		sdl.RenderSetLogicalSize(r, prev_lw, prev_lh)
		sdl.RenderSetIntegerScale(r, prev_int)
	}
	sdl.SetRenderDrawBlendMode(r, .BLEND)

	scale := clamp(i32(fh / 340.0), 1, 4)
	safe_top := touch_state.safe_insets[2] * fh
	safe_right := touch_state.safe_insets[1] * fw

	// Floating MENU button:
	//   - When on-screen touch controls are visible, place it in the open top bar
	//     between the Style pill and R1 so it never overlaps R1/R2 or Pause/Style.
	//   - Otherwise (gamepad/desktop), tuck it neatly in the top-right corner.
	btn_w := f32(56 * scale)
	btn_h := f32(20 * scale)
	btn_x := fw - safe_right - btn_w - f32(10 * scale)
	btn_y := max(safe_top + f32(6 * scale), f32(8 * scale))
	if touch_is_visible() {
		sp := touch_state.layout.style_pill
		r1 := touch_state.layout.pills[.R1]
		if sp.w > 0 && r1.x > sp.x + sp.w + btn_w + 4 {
			btn_x = sp.x + sp.w + (r1.x - (sp.x + sp.w) - btn_w) * 0.5
			btn_y = sp.y
			btn_h = max(btn_h, sp.h)
		}
	}
	btn_r := Quick_Rect{btn_x, btn_y, btn_w, btn_h}

	sync.mutex_lock(&quick_menu.lock)
	quick_menu.screen_w = fw
	quick_menu.screen_h = fh
	quick_menu.btn_rect = btn_r
	is_open := quick_menu.open
	active_tab := quick_menu.tab
	cursor := quick_menu.cursor
	sync.mutex_unlock(&quick_menu.lock)

	// Draw MENU pill button
	draw_box(r, btn_r, is_open ? sdl.Color{59, 106, 216, 235} : sdl.Color{18, 24, 38, 185}, sdl.Color{150, 185, 255, 220})
	draw_text_centered(r, "MENU", btn_r, scale, sdl.Color{240, 246, 255, 255})

	if !is_open {
		return
	}

	// Dim backdrop
	sdl.SetRenderDrawColor(r, 6, 10, 18, 175)
	bg_all := sdl.Rect{0, 0, out_w, out_h}
	sdl.RenderFillRect(r, &bg_all)

	// Center modal panel
	pw := min(fw * 0.86, f32(360 * scale))
	ph := min(fh * 0.86, f32(290 * scale))
	px := (fw - pw) * 0.5
	py := (fh - ph) * 0.5
	panel := Quick_Rect{px, py, pw, ph}

	draw_box(r, panel, sdl.Color{15, 21, 34, 244}, sdl.Color{92, 134, 224, 240})

	// Header bar + Close [X] button
	hdr_h := f32(24 * scale)
	hdr := Quick_Rect{px, py, pw, hdr_h}
	draw_box(r, hdr, sdl.Color{24, 34, 54, 255}, sdl.Color{70, 102, 170, 220})
	draw_text(r, "BOF4 SETTINGS", px + f32(10 * scale), py + f32(8 * scale), scale, sdl.Color{235, 243, 255, 255})

	close_w := f32(34 * scale)
	close_r := Quick_Rect{px + pw - close_w - f32(4 * scale), py + f32(3 * scale), close_w, hdr_h - f32(6 * scale)}
	draw_box(r, close_r, sdl.Color{135, 42, 58, 240}, sdl.Color{245, 160, 175, 220})
	draw_text_centered(r, "X", close_r, scale, sdl.Color{255, 240, 242, 255})

	// 4 Tabs row
	tab_y := py + hdr_h + f32(4 * scale)
	tab_h := f32(20 * scale)
	tab_gap := f32(4 * scale)
	tab_w := (pw - f32(16 * scale) - tab_gap * 3) / 4.0
	trects: [Quick_Tab]Quick_Rect
	for t in Quick_Tab {
		tx := px + f32(8 * scale) + f32(int(t)) * (tab_w + tab_gap)
		tr := Quick_Rect{tx, tab_y, tab_w, tab_h}
		trects[t] = tr
		sel := t == active_tab
		draw_box(
			r,
			tr,
			sel ? sdl.Color{54, 98, 204, 255} : sdl.Color{24, 32, 48, 230},
			sel ? sdl.Color{165, 200, 255, 255} : sdl.Color{64, 80, 112, 200},
		)
		draw_text_centered(r, QUICK_TAB_LABELS[t], tr, scale, sel ? sdl.Color{255, 255, 255, 255} : sdl.Color{170, 188, 214, 255})
	}

	// Rows area
	rows_y := tab_y + tab_h + f32(6 * scale)
	footer_h := f32(20 * scale)
	avail_h := (py + ph - footer_h - f32(4 * scale)) - rows_y
	total_rows := tab_row_count(active_tab)
	row_h := min(f32(21 * scale), avail_h / f32(max(min(total_rows, 9), 1)))
	vis_rows := clamp(int(avail_h / max(row_h, 1)), 1, min(total_rows, 12))
	scroll := quick_menu.scroll
	if cursor < scroll {
		scroll = cursor
	} else if cursor >= scroll + vis_rows {
		scroll = cursor - vis_rows + 1
	}
	scroll = clamp(scroll, 0, max(total_rows - vis_rows, 0))

	rrects: [12]Quick_Rect
	for i in 0 ..< vis_rows {
		row_idx := scroll + i
		ry := rows_y + f32(i) * row_h
		rr := Quick_Rect{px + f32(8 * scale), ry, pw - f32(16 * scale), row_h - f32(2 * scale)}
		rrects[i] = rr
		sel := row_idx == cursor
		draw_box(
			r,
			rr,
			sel ? sdl.Color{38, 60, 104, 245} : sdl.Color{20, 28, 44, 210},
			sel ? sdl.Color{122, 168, 255, 240} : sdl.Color{46, 58, 84, 180},
		)
		lbl, val := row_label_value(active_tab, row_idx)
		ty := rr.y + (rr.h - f32(8 * scale)) * 0.5
		draw_text(r, lbl, rr.x + f32(8 * scale), ty, scale, sdl.Color{225, 234, 248, 255})
		val_str := fmt.tprintf("< %s >", val)
		val_w := f32(len(val_str) * 8 * int(scale))
		draw_text(
			r,
			val_str,
			rr.x + rr.w - val_w - f32(8 * scale),
			ty,
			scale,
			sel ? sdl.Color{132, 232, 182, 255} : sdl.Color{146, 194, 255, 255},
		)
	}

	// Footer status / help hint
	foot_y := py + ph - footer_h + f32(4 * scale)
	foot_msg := "Tap option | Pad: DPad+A / L1 R1 | * = Restart"
	if quick_menu.note != "" && sdl.GetTicks() < quick_menu.note_until {
		foot_msg = quick_menu.note
	} else if active_tab == .Mods && len(mods_state.mods) == 0 {
		foot_msg = "Put mods in mods/<name>/ (see docs/modding.md)"
	}
	draw_text(r, foot_msg, px + f32(10 * scale), foot_y, max(scale - 1, 1), sdl.Color{166, 188, 218, 240})

	sync.mutex_lock(&quick_menu.lock)
	quick_menu.panel_rect = panel
	quick_menu.close_rect = close_r
	quick_menu.tab_rects = trects
	quick_menu.row_rects = rrects
	quick_menu.row_count = vis_rows
	quick_menu.scroll = scroll
	sync.mutex_unlock(&quick_menu.lock)
}

@(private = "file")
rect_hit :: #force_inline proc(r: Quick_Rect, x, y: f32) -> bool {
	return x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
}

@(private = "file")
draw_box :: proc(r: ^sdl.Renderer, q: Quick_Rect, fill, border: sdl.Color) {
	rc := sdl.Rect{i32(q.x), i32(q.y), i32(q.w), i32(q.h)}
	sdl.SetRenderDrawColor(r, fill.r, fill.g, fill.b, fill.a)
	sdl.RenderFillRect(r, &rc)
	sdl.SetRenderDrawColor(r, border.r, border.g, border.b, border.a)
	sdl.RenderDrawRect(r, &rc)
}

@(private = "file")
draw_text_centered :: proc(r: ^sdl.Renderer, s: string, q: Quick_Rect, scale: i32, col: sdl.Color) {
	tw := f32(len(s) * 8 * int(scale))
	th := f32(8 * scale)
	draw_text(r, s, q.x + (q.w - tw) * 0.5, q.y + (q.h - th) * 0.5, scale, col)
}

@(private = "file")
draw_text :: proc(r: ^sdl.Renderer, s: string, x, y: f32, scale: i32, col: sdl.Color) {
	if quick_menu.font_tex == nil {
		return
	}
	sdl.SetTextureColorMod(quick_menu.font_tex, col.r, col.g, col.b)
	sdl.SetTextureAlphaMod(quick_menu.font_tex, col.a)
	cx := i32(x)
	cy := i32(y)
	step := 8 * scale
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < 32 || ch > 126 {
			ch = '?'
		}
		idx := i32(ch - 32)
		src := sdl.Rect{(idx % 16) * 8, (idx / 16) * 8, 8, 8}
		dst := sdl.Rect{cx, cy, step, step}
		sdl.RenderCopy(r, quick_menu.font_tex, &src, &dst)
		cx += step
	}
}

@(private = "file")
ensure_font_atlas :: proc(r: ^sdl.Renderer) {
	if quick_menu.font_tex != nil && quick_menu.font_r == r {
		return
	}
	if quick_menu.font_tex != nil {
		sdl.DestroyTexture(quick_menu.font_tex)
		quick_menu.font_tex = nil
	}
	// 16 columns x 6 rows = 96 glyphs (ASCII 32..127), 8x8 each -> 128x48 pixels
	W :: 128
	H :: 48
	pix: [W * H]u32
	for ch in 0 ..< 95 {
		gx := (ch % 16) * 8
		gy := (ch / 16) * 8
		glyph := QM_FONT8X8[ch]
		for row in 0 ..< 8 {
			bits := glyph[row]
			for col in 0 ..< 8 {
				if (bits >> uint(col)) & 1 != 0 {
					pix[(gy + row) * W + (gx + col)] = 0xffffffff
				}
			}
		}
	}
	tex := sdl.CreateTexture(r, .ARGB8888, .STATIC, W, H)
	if tex == nil {
		return
	}
	sdl.SetTextureBlendMode(tex, .BLEND)
	sdl.SetTextureScaleMode(tex, .Nearest)
	sdl.UpdateTexture(tex, nil, &pix[0], W * 4)
	quick_menu.font_tex = tex
	quick_menu.font_r = r
}

// Public-domain 8x8 ASCII bitmap font (font8x8_basic, ASCII 32..126, LSB-left).
@(private = "file", rodata)
QM_FONT8X8 := [95][8]u8{
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, // ' '
	{0x18, 0x3C, 0x3C, 0x18, 0x18, 0x00, 0x18, 0x00}, // '!'
	{0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, // '"'
	{0x36, 0x36, 0x7F, 0x36, 0x7F, 0x36, 0x36, 0x00}, // '#'
	{0x0C, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x0C, 0x00}, // '$'
	{0x00, 0x63, 0x33, 0x18, 0x0C, 0x66, 0x63, 0x00}, // '%'
	{0x1C, 0x36, 0x1C, 0x6E, 0x3B, 0x33, 0x6E, 0x00}, // '&'
	{0x06, 0x06, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00}, // '\''
	{0x18, 0x0C, 0x06, 0x06, 0x06, 0x0C, 0x18, 0x00}, // '('
	{0x06, 0x0C, 0x18, 0x18, 0x18, 0x0C, 0x06, 0x00}, // ')'
	{0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00}, // '*'
	{0x00, 0x0C, 0x0C, 0x3F, 0x0C, 0x0C, 0x00, 0x00}, // '+'
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x06}, // ','
	{0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x00}, // '-'
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x00}, // '.'
	{0x60, 0x30, 0x18, 0x0C, 0x06, 0x03, 0x01, 0x00}, // '/'
	{0x3E, 0x63, 0x73, 0x7B, 0x6F, 0x67, 0x3E, 0x00}, // '0'
	{0x0C, 0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x3F, 0x00}, // '1'
	{0x1E, 0x33, 0x30, 0x1C, 0x06, 0x33, 0x3F, 0x00}, // '2'
	{0x1E, 0x33, 0x30, 0x1C, 0x30, 0x33, 0x1E, 0x00}, // '3'
	{0x38, 0x3C, 0x36, 0x33, 0x7F, 0x30, 0x78, 0x00}, // '4'
	{0x3F, 0x03, 0x1F, 0x30, 0x30, 0x33, 0x1E, 0x00}, // '5'
	{0x1C, 0x06, 0x03, 0x1F, 0x33, 0x33, 0x1E, 0x00}, // '6'
	{0x3F, 0x33, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x00}, // '7'
	{0x1E, 0x33, 0x33, 0x1E, 0x33, 0x33, 0x1E, 0x00}, // '8'
	{0x1E, 0x33, 0x33, 0x3E, 0x30, 0x18, 0x0E, 0x00}, // '9'
	{0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x00}, // ':'
	{0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x06}, // ';'
	{0x18, 0x0C, 0x06, 0x03, 0x06, 0x0C, 0x18, 0x00}, // '<'
	{0x00, 0x00, 0x3F, 0x00, 0x00, 0x3F, 0x00, 0x00}, // '='
	{0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00}, // '>'
	{0x1E, 0x33, 0x30, 0x18, 0x0C, 0x00, 0x0C, 0x00}, // '?'
	{0x3E, 0x63, 0x7B, 0x7B, 0x7B, 0x03, 0x1E, 0x00}, // '@'
	{0x0C, 0x1E, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x00}, // 'A'
	{0x3F, 0x66, 0x66, 0x3E, 0x66, 0x66, 0x3F, 0x00}, // 'B'
	{0x3C, 0x66, 0x03, 0x03, 0x03, 0x66, 0x3C, 0x00}, // 'C'
	{0x1F, 0x36, 0x66, 0x66, 0x66, 0x36, 0x1F, 0x00}, // 'D'
	{0x7F, 0x46, 0x16, 0x1E, 0x16, 0x46, 0x7F, 0x00}, // 'E'
	{0x7F, 0x46, 0x16, 0x1E, 0x16, 0x06, 0x0F, 0x00}, // 'F'
	{0x3C, 0x66, 0x03, 0x03, 0x73, 0x66, 0x7C, 0x00}, // 'G'
	{0x33, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x33, 0x00}, // 'H'
	{0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00}, // 'I'
	{0x78, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E, 0x00}, // 'J'
	{0x67, 0x66, 0x36, 0x1E, 0x36, 0x66, 0x67, 0x00}, // 'K'
	{0x0F, 0x06, 0x06, 0x06, 0x46, 0x66, 0x7F, 0x00}, // 'L'
	{0x63, 0x77, 0x7F, 0x7F, 0x6B, 0x63, 0x63, 0x00}, // 'M'
	{0x63, 0x67, 0x6F, 0x7B, 0x73, 0x63, 0x63, 0x00}, // 'N'
	{0x1C, 0x36, 0x63, 0x63, 0x63, 0x36, 0x1C, 0x00}, // 'O'
	{0x3F, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x0F, 0x00}, // 'P'
	{0x1E, 0x33, 0x33, 0x33, 0x3B, 0x1E, 0x38, 0x00}, // 'Q'
	{0x3F, 0x66, 0x66, 0x3E, 0x36, 0x66, 0x67, 0x00}, // 'R'
	{0x1E, 0x33, 0x07, 0x0E, 0x38, 0x33, 0x1E, 0x00}, // 'S'
	{0x3F, 0x2D, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00}, // 'T'
	{0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x3F, 0x00}, // 'U'
	{0x33, 0x33, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00}, // 'V'
	{0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00}, // 'W'
	{0x63, 0x63, 0x36, 0x1C, 0x1C, 0x36, 0x63, 0x00}, // 'X'
	{0x33, 0x33, 0x33, 0x1E, 0x0C, 0x0C, 0x1E, 0x00}, // 'Y'
	{0x7F, 0x63, 0x31, 0x18, 0x4C, 0x66, 0x7F, 0x00}, // 'Z'
	{0x1E, 0x06, 0x06, 0x06, 0x06, 0x06, 0x1E, 0x00}, // '['
	{0x03, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00}, // '\\'
	{0x1E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x1E, 0x00}, // ']'
	{0x08, 0x1C, 0x36, 0x63, 0x00, 0x00, 0x00, 0x00}, // '^'
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF}, // '_'
	{0x0C, 0x0C, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00}, // '`'
	{0x00, 0x00, 0x1E, 0x30, 0x3E, 0x33, 0x6E, 0x00}, // 'a'
	{0x07, 0x06, 0x06, 0x3E, 0x66, 0x66, 0x3B, 0x00}, // 'b'
	{0x00, 0x00, 0x1E, 0x33, 0x03, 0x33, 0x1E, 0x00}, // 'c'
	{0x38, 0x30, 0x30, 0x3E, 0x33, 0x33, 0x6E, 0x00}, // 'd'
	{0x00, 0x00, 0x1E, 0x33, 0x3F, 0x03, 0x1E, 0x00}, // 'e'
	{0x1C, 0x36, 0x06, 0x0F, 0x06, 0x06, 0x0F, 0x00}, // 'f'
	{0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x1F}, // 'g'
	{0x07, 0x06, 0x36, 0x6E, 0x66, 0x66, 0x67, 0x00}, // 'h'
	{0x0C, 0x00, 0x0E, 0x0C, 0x0C, 0x0C, 0x1E, 0x00}, // 'i'
	{0x30, 0x00, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E}, // 'j'
	{0x07, 0x06, 0x66, 0x36, 0x1E, 0x36, 0x67, 0x00}, // 'k'
	{0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00}, // 'l'
	{0x00, 0x00, 0x33, 0x7F, 0x7F, 0x6B, 0x63, 0x00}, // 'm'
	{0x00, 0x00, 0x1F, 0x33, 0x33, 0x33, 0x33, 0x00}, // 'n'
	{0x00, 0x00, 0x1E, 0x33, 0x33, 0x33, 0x1E, 0x00}, // 'o'
	{0x00, 0x00, 0x3B, 0x66, 0x66, 0x3E, 0x06, 0x0F}, // 'p'
	{0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x78}, // 'q'
	{0x00, 0x00, 0x3B, 0x6E, 0x66, 0x06, 0x0F, 0x00}, // 'r'
	{0x00, 0x00, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x00}, // 's'
	{0x08, 0x0C, 0x3E, 0x0C, 0x0C, 0x2C, 0x18, 0x00}, // 't'
	{0x00, 0x00, 0x33, 0x33, 0x33, 0x33, 0x6E, 0x00}, // 'u'
	{0x00, 0x00, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00}, // 'v'
	{0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00}, // 'w'
	{0x00, 0x00, 0x63, 0x36, 0x1C, 0x36, 0x63, 0x00}, // 'x'
	{0x00, 0x00, 0x33, 0x33, 0x33, 0x3E, 0x30, 0x1F}, // 'y'
	{0x00, 0x00, 0x3F, 0x19, 0x0C, 0x26, 0x3F, 0x00}, // 'z'
	{0x38, 0x0C, 0x0C, 0x07, 0x0C, 0x0C, 0x38, 0x00}, // '{'
	{0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x00}, // '|'
	{0x07, 0x0C, 0x0C, 0x38, 0x0C, 0x0C, 0x07, 0x00}, // '}'
	{0x6E, 0x3B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, // '~'
}
