# Android Port, Touch Controls, Gamepads & Optimizations

`bof4-recomp` includes a native Android port (`android/`) targeting Android 10+
(API 29+, `arm64-v8a` and optional `x86_64`), on-screen PlayStation 1 DualShock
and Digital touch controls, low-latency gamepad support, and mobile performance
optimizations.

## Requirements

- [Odin](https://odin-lang.org/) `dev-2026-11` or newer (includes `-subtarget:android`)
- Android NDK r26+ (`ANDROID_NDK_HOME` or `ODIN_ANDROID_NDK`)
- Android SDK (API 35) + JDK 17 + Gradle 8.x (or Android Studio)
- CMake 3.22+ and Ninja (or Make)
- Your legal US Breath of Fire IV disc image (`SLUS-01324`), already recompiled
  into `port/src/rec/` by running `./setup.sh` once on your build host

## Building the APK

1. Generate `port/src/rec/` from your disc on the host machine:
   ```sh
   ./setup.sh
   ```
2. Build the Android APK (`arm64-v8a` release by default with `--release`):
   ```sh
   export ANDROID_NDK_HOME=/path/to/android-ndk
   ./android/build.sh --release
   ```
   Useful flags:
   - `--debug` — debug build with symbols
   - `--fast-release` — adds `-no-bounds-check` for extra CPU headroom on slower phones
   - `--abi arm64-v8a,x86_64` — build for both ARM64 devices and x86_64 emulators
   - `--install` — install directly onto a connected device via `adb`

`android/build.sh` automatically:
1. Downloads SDL2 source into `android/sdl2/` if not already present (or set `SDL2_DIR`).
2. Stages a patched copy of `ps-recomp` in `android/build/ps-recomp/` using
   `patches/ps-recomp-android.patch` (keeping the `ps-recomp` git submodule clean).
3. Builds `libSDL2.so` via CMake + NDK and copies SDL2's Java Activity classes.
4. Cross-compiles `port/src` into `libbof4.so` (`-target:linux_arm64 -subtarget:android -build-mode:shared -o:speed`).
5. Packages `android/bof4-android-<build>.apk` via Gradle.

## Installing Your Disc Image on Android

The APK contains no copyrighted game files. On first launch, `DiscSetupActivity`
opens an import screen where you can select your `Breath of Fire IV.cue` and
both `.bin` tracks (or a single `.bin`/`.iso`) using Android's file picker — no
special storage permissions required.

Alternatively, push them over ADB into app storage:
```sh
adb push "Breath of Fire IV.cue" "Breath of Fire IV (Track 1).bin" "Breath of Fire IV (Track 2).bin" \
    /sdcard/Android/data/com.bof4recomp.app/files/
```
Memory cards (`bof4_slot1.mcd`, `bof4_slot2.mcd`) and `bof4.ini` live in the
same folder.

## On-Screen PS1 Touch Controls

Touch controls render directly in full physical screen coordinates (including
widescreen pillarbox margins and avoiding display notches/cutouts via
`BOF4_SAFE_*` insets) using pre-baked SDF anti-aliased SDL2 GPU textures:

- **Three layouts** (switchable in-game via the top-center `DS`/`DIG`/`ANA` pill
  or **Setting > Extras > Controls**):
  - `DualShock`: 8-way slideable D-pad + Left/Right analog sticks + PS1 △ ○ ✕ □
    diamond + L1/L2/R1/R2 + Select/Start
  - `Digital`: Larger classic PS1 D-pad and face buttons without sticks
  - `Analog`: Large Left analog stick + Right analog stick + face/shoulder buttons
- **Authentic PlayStation layout & orientation**:
  - Triangle (top, green), Circle (right, red), Cross (bottom, blue), Square (left, pink)
  - Analog sticks and 8-way D-pad use exact screen/SDL/PS1 coordinates (`+x` right,
    `+y` down — never inverted)
  - Up to 10-finger multi-touch with per-finger capture and clean release on
    backgrounding
  - Dragging open game area pans the camera horizontally (`[touch] camera_drag`)
  - Automatically hides when you press any button or move a stick on a physical
    gamepad (`[touch] mode = auto`), and switches in-game button prompts to
    PlayStation symbols when touching the screen

## Gamepad Support

- **Plug-and-play Bluetooth & USB-C controllers**: DualShock 4, DualSense PS5,
  Xbox One/Series, Nintendo Switch Pro / Joy-Con, 8BitDo, Backbone One, Razer
  Kishi, GameSir, Retroid, AYN Odin, NVIDIA Shield, Logitech, and generic HID
  gamepads.
- **Anti-inversion & anti-quirk guarantees**:
  - `SDL_HINT_ACCELEROMETER_AS_JOYSTICK=0` prevents phone accelerometers from
    registering as Joystick 0.
  - `SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS=0` enforces positional South=Cross,
    East=Circle, West=Square, North=Triangle across all controllers (optional
    `[pad] swap_confirm = true` swaps Cross/Circle if preferred).
  - `SDL_HINT_TOUCH_MOUSE_EVENTS=0` + event filtering drops synthetic touch->mouse
    clicks so screen touches never trigger Mouse Left (`PAD_CROSS`).
  - Embedded `GameControllerDB` mappings plus a raw `SDL_Joystick` fallback with
    automatic unipolar (`0..32767`) vs bipolar (`-32768..32767`) L2/R2 trigger
    calibration.
- **Low latency**:
  - Post-sleep/post-vsync event polling eliminates up to 1 full frame (~16.7 ms)
    of input delay before each vblank pad read.
  - Immediate SDL event watch + 2-poll quick-tap latch prevents missed rapid taps
    on BOF4's 30 fps logic ticks without delaying button presses or held releases.
  - Configurable `[pad] deadzone` (default `0.15`), `[pad] trigger_threshold`
    (default `0.25` with hysteresis), and `[pad] rumble` (0–100%).

## Optimizations (`Setting > Extras > Perf`)

- **Auto Vulkan / Software scaling (`[perf] profile = auto`)**: Uses Vulkan 1.3
  at Detail `x2` on supported mobile GPUs; automatically drops to fast Detail `x1`
  with heavy software post-FX disabled if a device falls back to the CPU software
  rasterizer. Presets: `Auto`, `Quality`, `Balanced`, `Battery`.
- **VRAM dirty-band repeat-frame skip (`[perf] skip_repeat_upload = true`)**:
  Tracks 16-row VRAM write bands and skips redundant CPU pixel conversion and
  `SDL_UpdateTexture` uploads on repeated frames (~50% less memory bandwidth at
  BOF4's 30 fps field/battle cadence).
- **4-wide SIMD (ARM64 NEON / x86 SSE2) 15-bit framebuffer conversion** at
  Detail `x1` and contiguous row fast-paths at Detail `x2`/`x4`.
- **Power-efficient pacing (`[perf] low_power_pacing`) & mobile spin tuning**:
  Replaces the 1 ms end-of-frame busy-spin with sleep + `thread.yield()` and
  shortens worker spin rounds on Android to keep phones cool and avoid thermal
  throttling.
- **big.LITTLE-aware thread pool (`[perf] raster_threads`)**: Caps automatic
  software raster bands to 4 on Android so efficiency cores don't bottleneck
  frame sync.
- **Bounded interior cache & `APP_LOWMEMORY` trimming (`[perf] max_cached_rooms`)**:
  Defaults to 4 cached room worlds on Android (saving ~14 MB RAM) and frees
  non-active room worlds immediately when Android signals low memory.

## In-Game Quick Settings Menu & Modding

Tap the floating **`MENU`** button in the top bar (or press **`L3 + R3`** on a
gamepad / Android **Back** button / **`F1`** on desktop) at any time to open the
in-game overlay menu without leaving the game:

- **VIDEO**: Change **Resolution** (`1x` / `2x` / `4x`), **FPS Limit** (`30` /
  `60` / `90` / `120` / `Unlimited`), **Graphics API** (`OpenGL ES` / `Vulkan`),
  **Anti-Wobble (PGXP)**, **Screen Filter** (`Linear` / `Nearest`), **Soft
  Texels**, **Scaling**, and **60 FPS Motion**.
- **AUDIO**: Toggle **Audio Smooth Fix** (click-free adaptive rate tracking +
  fade-out/fade-in underrun smoothing), tune **Audio Latency** (`40–320 ms`,
  Android default `140 ms`), and adjust **Master Volume**.
- **CONTROLS**: Adjust touch mode/layout/opacity/scale, vibration, and stick
  deadzone live.
- **MODS**: Enable/disable mods and custom PNG texture packs live, toggle
  **Dump Textures**, reload mods on the fly, toggle individual installed mods,
  or import `.zip` mod archives from the launcher (**Import Mod (.zip)**).

See **[`docs/modding.md`](modding.md)** for the complete modding & HD texture
pack creation manual.

