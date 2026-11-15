package com.bof4recomp.app;

import android.content.Context;
import android.graphics.Insets;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.system.Os;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.DisplayCutout;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;

import org.libsdl.app.SDLActivity;

import java.io.File;
import java.util.Locale;

/**
 * Main SDL2 Activity for Breath of Fire IV (bof4-recomp).
 *
 * Configures low-latency immersive landscape display, display-cutout safe-area
 * insets for the on-screen PS1 touch controls, sustained performance mode, and
 * loads libSDL2.so + libbof4.so (exporting SDL_main from Odin).
 */
public class Bof4Activity extends SDLActivity {
    private static final String TAG = "Bof4Activity";
    private File dataDir;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        dataDir = resolveDataDir(this);
        if (!dataDir.exists()) {
            dataDir.mkdirs();
        }
        exportEnvironment(dataDir);

        Window win = getWindow();
        if (win != null) {
            win.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            WindowManager.LayoutParams lp = win.getAttributes();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                lp.layoutInDisplayCutoutMode =
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
                win.setAttributes(lp);
            }
            enableSustainedPerformance(win);
        }
        setVolumeControlStream(AudioManager.STREAM_MUSIC);

        super.onCreate(savedInstanceState);
        applyImmersiveMode();
        attachCutoutListener();
    }

    @Override
    protected void onResume() {
        super.onResume();
        applyImmersiveMode();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            applyImmersiveMode();
        }
    }

    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL2", "bof4" };
    }

    @Override
    protected String getMainSharedObject() {
        return getContext().getApplicationInfo().nativeLibraryDir + "/libbof4.so";
    }

    @Override
    protected String getMainFunction() {
        return "SDL_main";
    }

    @Override
    protected String[] getArguments() {
        File dir = dataDir != null ? dataDir : resolveDataDir(this);
        return new String[] { dir.getAbsolutePath() };
    }

    public static File resolveDataDir(Context ctx) {
        File ext = ctx.getExternalFilesDir(null);
        if (ext != null) {
            return ext;
        }
        return ctx.getFilesDir();
    }

    private void exportEnvironment(File dir) {
        try {
            Os.setenv("BOF4_DATA_DIR", dir.getAbsolutePath(), true);
        } catch (Exception e) {
            Log.w(TAG, "Failed to set BOF4_DATA_DIR", e);
        }
    }

    private void attachCutoutListener() {
        View decor = getWindow() != null ? getWindow().getDecorView() : null;
        if (decor == null) {
            return;
        }
        decor.setOnApplyWindowInsetsListener((v, insets) -> {
            updateSafeInsets(insets);
            return v.onApplyWindowInsets(insets);
        });
        WindowInsets current = decor.getRootWindowInsets();
        if (current != null) {
            updateSafeInsets(current);
        }
    }

    private void updateSafeInsets(WindowInsets insets) {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        float w = Math.max(dm.widthPixels, 1);
        float h = Math.max(dm.heightPixels, 1);
        float left = 0f, right = 0f, top = 0f, bottom = 0f;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Insets cutout = insets.getInsets(WindowInsets.Type.displayCutout());
            left = cutout.left / w;
            right = cutout.right / w;
            top = cutout.top / h;
            bottom = cutout.bottom / h;
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            DisplayCutout dc = insets.getDisplayCutout();
            if (dc != null) {
                left = dc.getSafeInsetLeft() / w;
                right = dc.getSafeInsetRight() / w;
                top = dc.getSafeInsetTop() / h;
                bottom = dc.getSafeInsetBottom() / h;
            }
        }
        try {
            Os.setenv("BOF4_SAFE_LEFT", String.format(Locale.US, "%.4f", left), true);
            Os.setenv("BOF4_SAFE_RIGHT", String.format(Locale.US, "%.4f", right), true);
            Os.setenv("BOF4_SAFE_TOP", String.format(Locale.US, "%.4f", top), true);
            Os.setenv("BOF4_SAFE_BOTTOM", String.format(Locale.US, "%.4f", bottom), true);
        } catch (Exception e) {
            Log.w(TAG, "Failed to export safe insets", e);
        }
    }

    private void enableSustainedPerformance(Window win) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                if (pm != null && pm.isSustainedPerformanceModeSupported()) {
                    win.setSustainedPerformanceMode(true);
                }
            } catch (Exception e) {
                Log.d(TAG, "Sustained performance mode not available", e);
            }
        }
    }

    @SuppressWarnings("deprecation")
    private void applyImmersiveMode() {
        Window win = getWindow();
        if (win == null) {
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            win.setDecorFitsSystemWindows(false);
            WindowInsetsController ctrl = win.getInsetsController();
            if (ctrl != null) {
                ctrl.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                ctrl.setSystemBarsBehavior(
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            View decor = win.getDecorView();
            if (decor != null) {
                decor.setSystemUiVisibility(
                        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                                | View.SYSTEM_UI_FLAG_FULLSCREEN);
            }
        }
    }
}
