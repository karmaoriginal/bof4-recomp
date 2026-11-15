// Mobile and cross-platform performance optimization controller.
//
// Coordinates adaptive detail fallback (if a mobile GPU lacks Vulkan 1.3 and
// falls back to software rendering), power-efficient frame pacing, repeat-frame
// VRAM upload skipping, big.LITTLE-aware raster thread count, and Android
// low-memory cache trimming.
package qol

import "core:fmt"
import "core:os"
import "core:strconv"

import "ps:core"
import host "ps:psx/host"
import render "ps:psx/render"

@(private)
Perf_Profile :: enum u8 {
	Auto,     // Hardware-aware: Vulkan x2 or fast Software x1 on mobile
	Quality,  // Max visual fidelity (Detail x2 + effects)
	Balanced, // Smooth 60 fps + low-power pacing + repeat-frame skip
	Battery,  // Coolest & longest battery (Detail x1, effects off, min RAM)
}

@(private)
PERF_PROFILE_TEXT := [Perf_Profile]string {
	.Auto     = "Auto",
	.Quality  = "Quality",
	.Balanced = "Balanced",
	.Battery  = "Battery",
}

@(private)
PERF_PROFILE_KEYS := [Perf_Profile]string {
	.Auto     = "auto",
	.Quality  = "quality",
	.Balanced = "balanced",
	.Battery  = "battery",
}

// Tracks whether the user explicitly set [window] detail or hardware in
// bof4.ini so Android safe defaults never override a deliberate user preference.
@(private)
config_detail_explicit: bool
@(private)
config_hardware_explicit: bool

// Apply pre-init thread/pacing tuning (called from qol.boot() before
// host.platform_init starts the raster thread pool).
@(private)
mobile_opt_boot :: proc() {
	if core.headless {
		return
	}
	// On Android, default to the fast NEON-accelerated software renderer at
	// Detail x1 unless the user explicitly enabled Vulkan hardware rendering
	// in bof4.ini. Many mobile Vulkan 1.3 drivers reject desktop-class SPIR-V
	// features or large contiguous staging buffers and abort via vk_check.
	when ODIN_PLATFORM_SUBTARGET == .Android {
		if !config_hardware_explicit {
			config.window_hardware = false
		}
		if !config_detail_explicit && !config.window_hardware {
			config.window.detail = .X1
			config.window_bloom_effects = false
			config.window_depth_of_field = false
		}
	}
	// Optional BOF4_RASTER_THREADS environment override.
	if s := os.get_env("BOF4_RASTER_THREADS", context.temp_allocator); s != "" {
		if n, ok := strconv.parse_int(s); ok && n >= 0 && n <= int(render.MAX_BANDS) {
			config.perf_raster_threads = n
		}
	}
	when PS_ANDROID_PATCH {
		render.raster_threads_override = i32(clamp(config.perf_raster_threads, 0, int(render.MAX_BANDS)))
		host.low_power_pacing = config.perf_low_power_pacing
		host.skip_repeat_upload = config.perf_skip_repeat_upload
	}
}

// Apply post-init GPU-aware optimization after Vulkan/software renderer probing.
@(private)
mobile_opt_init :: proc() {
	if core.headless {
		return
	}
	when PS_ANDROID_PATCH {
		host.low_memory_hook = interiors_trim_cache
	}
	mobile_opt_apply_flags()

	// On Android, if Vulkan 1.3 hardware rendering was unavailable and the
	// renderer fell back to the CPU software rasterizer, automatically step
	// down from Detail x2 to crisp full-speed Detail x1 unless the user
	// explicitly set detail in bof4.ini.
	when ODIN_PLATFORM_SUBTARGET == .Android {
		if config.perf_profile == .Auto && !render.gpu_frames() && !config_detail_explicit {
			if config.window.detail != .X1 {
				config.window.detail = .X1
				config.window_bloom_effects = false
				config.window_depth_of_field = false
				apply_effects()
				host.window_apply(config.window)
				fmt.eprintln("perf: Android software fallback active; auto-selected Detail x1 for full speed")
				host.osd_toast("Software GPU: Detail x1")
			}
		}
	}
	if config.perf_profile != .Auto {
		mobile_opt_apply_profile()
	}
}

// Push low-level host optimization flags live (zero restart needed).
@(private)
mobile_opt_apply_flags :: proc() {
	when PS_ANDROID_PATCH {
		host.low_power_pacing = config.perf_low_power_pacing
		host.skip_repeat_upload = config.perf_skip_repeat_upload
		render.raster_threads_override = i32(clamp(config.perf_raster_threads, 0, int(render.MAX_BANDS)))
	}
	interiors_enforce_cache_limit()
}

// Apply a user-selected performance profile immediately.
@(private)
mobile_opt_apply_profile :: proc() {
	gpu_ok := render.gpu_frames()
	switch config.perf_profile {
	case .Auto:
		when ODIN_PLATFORM_SUBTARGET == .Android {
			config.perf_low_power_pacing = true
			config.perf_skip_repeat_upload = true
			config.perf_max_cached_rooms = 4
			if !gpu_ok {
				config.window.detail = .X1
				config.window_bloom_effects = false
				config.window_depth_of_field = false
			} else {
				config.window.detail = .X2
			}
		} else {
			config.perf_low_power_pacing = false
			config.perf_skip_repeat_upload = true
			config.perf_max_cached_rooms = 8
		}
	case .Quality:
		config.window.detail = .X2
		config.perf_low_power_pacing = false
		config.perf_skip_repeat_upload = true
		config.window_bloom_effects = true
		config.window_depth_of_field = true
		config.window_vignette = true
		config.window_color_grade = true
	case .Balanced:
		config.window.detail = gpu_ok ? .X2 : .X1
		config.perf_low_power_pacing = true
		config.perf_skip_repeat_upload = true
		config.window_bloom_effects = gpu_ok
		config.window_depth_of_field = false
		config.window_vignette = true
		config.window_color_grade = true
		config.perf_max_cached_rooms = 4
	case .Battery:
		config.window.detail = .X1
		config.perf_low_power_pacing = true
		config.perf_skip_repeat_upload = true
		config.window_bloom_effects = false
		config.window_depth_of_field = false
		config.window_smooth_effects = false
		config.window_smooth_textures = false
		config.window_vignette = false
		config.perf_max_cached_rooms = 2
	}
	apply_effects()
	host.window_apply(config.window)
	mobile_opt_apply_flags()
}
