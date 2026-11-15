package com.bof4recomp.app;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Lightweight launcher, validated disc importer, and crash-diagnostic screen.
 *
 * - Validates that any .cue sheet has ALL referenced .bin tracks present
 *   (case-insensitive) and that standalone .bin/.iso images contain an ISO9660
 *   PlayStation volume ("CD001") before launching Bof4Activity.
 * - Allows picking disc files all at once OR one-by-one without premature launch.
 * - Prevents silent closes & crash loops: if a previous launch failed or crashed
 *   before frame 1, displays bof4_last_error.txt / bof4_boot.log right on screen.
 */
public class DiscSetupActivity extends Activity {
    private static final String TAG = "DiscSetupActivity";
    private static final int REQ_PICK_DISC = 1001;

    public static final String EXTRA_SHOW_ERROR = "bof4_show_error";
    public static final String LAST_ERROR_FILE = "bof4_last_error.txt";
    public static final String BOOT_LOG_FILE = "bof4_boot.log";
    public static final String LAUNCH_FLAG_FILE = "bof4_launching.flag";

    private File dataDir;
    private TextView filesText;
    private TextView statusText;
    private TextView errorBox;
    private ProgressBar progressBar;
    private Button pickButton;
    private Button launchButton;
    private Button clearButton;
    private Button copyLogButton;
    private String lastLogContent = "";
    private final ExecutorService ioPool = Executors.newSingleThreadExecutor();

    private static final class DiscStatus {
        boolean ready;
        String message;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        dataDir = Bof4Activity.resolveDataDir(this);
        if (!dataDir.exists()) {
            dataDir.mkdirs();
        }

        boolean showError = getIntent().getBooleanExtra(EXTRA_SHOW_ERROR, false);
        File errFile = new File(dataDir, LAST_ERROR_FILE);
        File flagFile = new File(dataDir, LAUNCH_FLAG_FILE);
        boolean hadCrashOrError = showError || errFile.isFile() || flagFile.isFile();

        DiscStatus st = validateDisc(dataDir);
        if (st.ready && !hadCrashOrError) {
            launchGame();
            return;
        }

        buildSetupUi();
        refreshUi(hadCrashOrError);
    }

    @Override
    protected void onDestroy() {
        ioPool.shutdownNow();
        super.onDestroy();
    }

    private void launchGame() {
        deleteQuietly(new File(dataDir, LAST_ERROR_FILE));
        deleteQuietly(new File(dataDir, LAUNCH_FLAG_FILE));
        Intent intent = new Intent(this, Bof4Activity.class);
        startActivity(intent);
        overridePendingTransition(0, 0);
        finish();
    }

    private void buildSetupUi() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.parseColor("#0F141E"));
        scroll.setFillViewport(true);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = dp(20);
        root.setPadding(pad, pad, pad, pad);

        TextView heading = new TextView(this);
        heading.setText(R.string.setup_heading);
        heading.setTextColor(Color.parseColor("#EAF1FF"));
        heading.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        heading.setTypeface(Typeface.DEFAULT_BOLD);
        heading.setGravity(Gravity.CENTER);
        root.addView(heading);

        TextView body = new TextView(this);
        body.setText(getString(R.string.setup_body, dataDir.getAbsolutePath()));
        body.setTextColor(Color.parseColor("#B4C0D6"));
        body.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        body.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams bodyLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        bodyLp.topMargin = dp(8);
        bodyLp.bottomMargin = dp(12);
        root.addView(body, bodyLp);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER);

        pickButton = makeButton(R.string.setup_pick_button, "#3B6AD8", Color.WHITE);
        pickButton.setOnClickListener(v -> openFilePicker());

        launchButton = makeButton(R.string.setup_launch_button, "#25855A", Color.WHITE);
        launchButton.setOnClickListener(v -> {
            DiscStatus st = validateDisc(dataDir);
            if (st.ready) {
                launchGame();
            } else {
                statusText.setTextColor(Color.parseColor("#F6AD55"));
                statusText.setText(st.message);
            }
        });

        clearButton = makeButton(R.string.setup_clear_button, "#552832", Color.parseColor("#FFD6DC"));
        clearButton.setOnClickListener(v -> clearDiscFiles());

        copyLogButton = makeButton(R.string.setup_copy_log_button, "#2D3748", Color.parseColor("#E2E8F0"));
        copyLogButton.setVisibility(View.GONE);
        copyLogButton.setOnClickListener(v -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null && !lastLogContent.isEmpty()) {
                cm.setPrimaryClip(ClipData.newPlainText("BOF4 Log", lastLogContent));
                Toast.makeText(this, "Error log copied to clipboard", Toast.LENGTH_SHORT).show();
            }
        });

        LinearLayout.LayoutParams btnLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        btnLp.rightMargin = dp(8);
        buttons.addView(pickButton, btnLp);
        buttons.addView(launchButton, btnLp);
        buttons.addView(clearButton, btnLp);
        buttons.addView(copyLogButton);
        root.addView(buttons);

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setIndeterminate(true);
        progressBar.setVisibility(View.GONE);
        LinearLayout.LayoutParams pbLp = new LinearLayout.LayoutParams(
                dp(320), LinearLayout.LayoutParams.WRAP_CONTENT);
        pbLp.topMargin = dp(10);
        root.addView(progressBar, pbLp);

        statusText = new TextView(this);
        statusText.setTextColor(Color.parseColor("#8FA9D9"));
        statusText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        statusText.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams stLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        stLp.topMargin = dp(10);
        root.addView(statusText, stLp);

        filesText = new TextView(this);
        filesText.setTextColor(Color.parseColor("#9FB1CC"));
        filesText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        filesText.setTypeface(Typeface.MONOSPACE);
        filesText.setBackgroundColor(Color.parseColor("#161D2B"));
        int fp = dp(10);
        filesText.setPadding(fp, fp, fp, fp);
        LinearLayout.LayoutParams fLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        fLp.topMargin = dp(10);
        root.addView(filesText, fLp);

        errorBox = new TextView(this);
        errorBox.setTextColor(Color.parseColor("#FEB2B2"));
        errorBox.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        errorBox.setTypeface(Typeface.MONOSPACE);
        errorBox.setBackgroundColor(Color.parseColor("#2A151B"));
        errorBox.setPadding(fp, fp, fp, fp);
        errorBox.setVisibility(View.GONE);
        LinearLayout.LayoutParams eLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        eLp.topMargin = dp(10);
        root.addView(errorBox, eLp);

        scroll.addView(root);
        setContentView(scroll);
    }

    private Button makeButton(int textRes, String bgHex, int fgColor) {
        Button b = new Button(this);
        b.setText(textRes);
        b.setAllCaps(false);
        b.setTextColor(fgColor);
        b.setBackgroundColor(Color.parseColor(bgHex));
        b.setPadding(dp(14), dp(10), dp(14), dp(10));
        return b;
    }

    private void refreshUi(boolean showPreviousError) {
        DiscStatus st = validateDisc(dataDir);
        launchButton.setEnabled(st.ready);
        launchButton.setAlpha(st.ready ? 1.0f : 0.45f);
        statusText.setTextColor(st.ready ? Color.parseColor("#68D391") : Color.parseColor("#F6AD55"));
        statusText.setText(st.message);
        filesText.setText(formatFileList(dataDir));

        if (showPreviousError) {
            String errText = readDiagnosticLog(dataDir);
            deleteQuietly(new File(dataDir, LAST_ERROR_FILE));
            deleteQuietly(new File(dataDir, LAUNCH_FLAG_FILE));
            if (!errText.isEmpty()) {
                lastLogContent = errText;
                errorBox.setText(errText);
                errorBox.setVisibility(View.VISIBLE);
                copyLogButton.setVisibility(View.VISIBLE);
            }
        }
    }

    private void clearDiscFiles() {
        File[] files = dataDir.listFiles();
        if (files != null) {
            for (File f : files) {
                if (!f.isFile()) {
                    continue;
                }
                String low = f.getName().toLowerCase(Locale.US);
                // Keep memory card saves (.mcd) and config (.ini); clear disc files & logs.
                if (low.endsWith(".mcd") || low.endsWith(".ini")) {
                    continue;
                }
                deleteQuietly(f);
            }
        }
        errorBox.setVisibility(View.GONE);
        copyLogButton.setVisibility(View.GONE);
        lastLogContent = "";
        refreshUi(false);
    }

    private void openFilePicker() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        startActivityForResult(intent, REQ_PICK_DISC);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_PICK_DISC || resultCode != RESULT_OK || data == null) {
            return;
        }
        List<Uri> uris = new ArrayList<>();
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                Uri u = clip.getItemAt(i).getUri();
                if (u != null) {
                    uris.add(u);
                }
            }
        } else if (data.getData() != null) {
            uris.add(data.getData());
        }
        if (!uris.isEmpty()) {
            importUris(uris);
        }
    }

    private void importUris(List<Uri> uris) {
        pickButton.setEnabled(false);
        launchButton.setEnabled(false);
        clearButton.setEnabled(false);
        progressBar.setVisibility(View.VISIBLE);

        ioPool.execute(() -> {
            byte[] buf = new byte[256 * 1024];
            String unsupportedWarning = null;
            for (Uri uri : uris) {
                String name = queryDisplayName(uri);
                if (name == null || name.isEmpty()) {
                    continue;
                }
                name = new File(name).getName();
                String low = name.toLowerCase(Locale.US);
                if (low.endsWith(".zip") || low.endsWith(".7z") || low.endsWith(".rar")
                        || low.endsWith(".chd") || low.endsWith(".ecm") || low.endsWith(".pbp")) {
                    unsupportedWarning = "Unsupported format: " + name
                            + "\nPlease extract/convert to raw .cue + .bin (or .iso) first.";
                    continue;
                }
                final String finalName = name;
                runOnUiThread(() -> statusText.setText(getString(R.string.setup_copying, finalName)));
                File dst = new File(dataDir, finalName);
                try (InputStream in = getContentResolver().openInputStream(uri);
                     FileOutputStream out = new FileOutputStream(dst)) {
                    if (in == null) {
                        continue;
                    }
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        out.write(buf, 0, n);
                    }
                    out.flush();
                } catch (Exception e) {
                    Log.e(TAG, "Failed importing " + finalName, e);
                    unsupportedWarning = "Error copying " + finalName + ": " + e.getMessage();
                }
            }
            final String warn = unsupportedWarning;
            runOnUiThread(() -> {
                progressBar.setVisibility(View.GONE);
                pickButton.setEnabled(true);
                clearButton.setEnabled(true);
                errorBox.setVisibility(View.GONE);
                copyLogButton.setVisibility(View.GONE);
                DiscStatus st = validateDisc(dataDir);
                filesText.setText(formatFileList(dataDir));
                launchButton.setEnabled(st.ready);
                launchButton.setAlpha(st.ready ? 1.0f : 0.45f);
                if (warn != null) {
                    statusText.setTextColor(Color.parseColor("#FC8181"));
                    statusText.setText(warn);
                } else if (st.ready) {
                    statusText.setTextColor(Color.parseColor("#68D391"));
                    statusText.setText(R.string.setup_ready);
                    launchGame();
                } else {
                    statusText.setTextColor(Color.parseColor("#F6AD55"));
                    statusText.setText(st.message);
                }
            });
        });
    }

    /**
     * Thoroughly validate disc files in dir before launching native code.
     * - If a .cue file exists, verifies EVERY referenced FILE exists in dir (case-insensitive).
     * - Otherwise verifies a .iso/.bin/.img file has an ISO9660 "CD001" PlayStation header.
     */
    private static DiscStatus validateDisc(File dir) {
        DiscStatus st = new DiscStatus();
        File[] files = dir != null ? dir.listFiles() : null;
        if (files == null || files.length == 0) {
            st.ready = false;
            st.message = "No disc files imported yet. Tap 'Add Disc Files' to select your .cue + .bin tracks (or .iso).";
            return st;
        }

        List<File> cues = new ArrayList<>();
        List<File> imgs = new ArrayList<>();
        for (File f : files) {
            if (!f.isFile()) {
                continue;
            }
            String low = f.getName().toLowerCase(Locale.US);
            if (low.endsWith(".cue")) {
                cues.add(f);
            } else if (low.endsWith(".bin") || low.endsWith(".iso") || low.endsWith(".img")) {
                imgs.add(f);
            }
        }

        if (!cues.isEmpty()) {
            File cue = cues.get(0);
            for (File c : cues) {
                if (c.getName().equalsIgnoreCase("Breath of Fire IV.cue")) {
                    cue = c;
                    break;
                }
            }
            List<String> referenced = parseCueFiles(cue);
            if (referenced.isEmpty()) {
                st.ready = false;
                st.message = "The .cue sheet '" + cue.getName() + "' has no FILE entries.";
                return st;
            }
            List<String> missing = new ArrayList<>();
            boolean hasIso9660 = false;
            for (String ref : referenced) {
                File matched = findFileCaseInsensitive(files, ref);
                if (matched == null) {
                    missing.add(ref);
                } else if (fileHasIso9660(matched)) {
                    hasIso9660 = true;
                }
            }
            if (!missing.isEmpty()) {
                st.ready = false;
                st.message = "Missing track file(s) listed in " + cue.getName() + ":\n• "
                        + joinLines(missing)
                        + "\nTap 'Add Disc Files' to add the missing .bin file(s).";
                return st;
            }
            if (!hasIso9660) {
                st.ready = false;
                st.message = "The .bin track(s) referenced by " + cue.getName()
                        + " do not contain a valid PlayStation ISO9660 filesystem (CD001).";
                return st;
            }
            st.ready = true;
            st.message = "Ready: " + cue.getName() + " (" + referenced.size() + " track file(s) verified).";
            return st;
        }

        if (!imgs.isEmpty()) {
            for (File img : imgs) {
                if (fileHasIso9660(img)) {
                    st.ready = true;
                    st.message = "Ready: " + img.getName() + " (PS1 disc verified; adding the .cue is recommended for CD audio).";
                    return st;
                }
            }
            st.ready = false;
            st.message = "Found .bin/.iso file(s), but none contain a PS1 data track (CD001).\n"
                    + "If you only added Track 2 (audio), please also add Track 1 (.bin) and the .cue file.";
            return st;
        }

        st.ready = false;
        st.message = "No .cue, .bin, or .iso disc files found yet. Tap 'Add Disc Files'.";
        return st;
    }

    private static List<String> parseCueFiles(File cue) {
        List<String> out = new ArrayList<>();
        try (BufferedReader br = new BufferedReader(
                new InputStreamReader(new FileInputStream(cue), StandardCharsets.UTF_8))) {
            String line;
            boolean first = true;
            while ((line = br.readLine()) != null) {
                if (first) {
                    first = false;
                    if (!line.isEmpty() && line.charAt(0) == '\uFEFF') {
                        line = line.substring(1);
                    }
                }
                String trimmed = line.trim();
                if (trimmed.length() < 5) {
                    continue;
                }
                String upper = trimmed.toUpperCase(Locale.US);
                if (!upper.startsWith("FILE ") && !upper.startsWith("FILE\t")) {
                    continue;
                }
                String rest = trimmed.substring(4).trim();
                String name;
                int q1 = rest.indexOf('"');
                int q2 = rest.lastIndexOf('"');
                if (q1 >= 0 && q2 > q1) {
                    name = rest.substring(q1 + 1, q2);
                } else {
                    int sp = rest.lastIndexOf(' ');
                    name = sp > 0 ? rest.substring(0, sp).trim() : rest;
                }
                int slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
                if (slash >= 0) {
                    name = name.substring(slash + 1);
                }
                if (!name.isEmpty()) {
                    out.add(name);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Failed parsing cue: " + cue, e);
        }
        return out;
    }

    private static File findFileCaseInsensitive(File[] files, String targetName) {
        for (File f : files) {
            if (f.isFile() && f.getName().equalsIgnoreCase(targetName)) {
                return f;
            }
        }
        return null;
    }

    private static boolean fileHasIso9660(File file) {
        long len = file.length();
        long[] offsets = new long[] {
                16L * 2352L + 24L + 1L, // Mode 2 Form 1 (standard PS1 raw .bin)
                16L * 2352L + 16L + 1L, // Mode 1 raw .bin
                16L * 2048L + 1L        // 2048-byte .iso
        };
        byte[] magic = new byte[5];
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            for (long off : offsets) {
                if (len >= off + 5) {
                    raf.seek(off);
                    if (raf.read(magic) == 5
                            && magic[0] == 'C' && magic[1] == 'D' && magic[2] == '0'
                            && magic[3] == '0' && magic[4] == '1') {
                        return true;
                    }
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "ISO9660 probe failed for " + file.getName(), e);
        }
        return false;
    }

    private static String formatFileList(File dir) {
        File[] files = dir != null ? dir.listFiles() : null;
        if (files == null || files.length == 0) {
            return "Files in storage: (none)";
        }
        Arrays.sort(files, Comparator.comparing(File::getName, String.CASE_INSENSITIVE_ORDER));
        StringBuilder sb = new StringBuilder("Files in storage:\n");
        int count = 0;
        for (File f : files) {
            if (!f.isFile()) {
                continue;
            }
            String n = f.getName();
            if (n.equals(BOOT_LOG_FILE) || n.equals(LAST_ERROR_FILE) || n.equals(LAUNCH_FLAG_FILE)) {
                continue;
            }
            double mb = f.length() / (1024.0 * 1024.0);
            sb.append(String.format(Locale.US, "  • %s (%.1f MB)\n", n, mb));
            count++;
        }
        if (count == 0) {
            return "Files in storage: (none)";
        }
        return sb.toString().trim();
    }

    private static String readDiagnosticLog(File dir) {
        StringBuilder sb = new StringBuilder();
        File errFile = new File(dir, LAST_ERROR_FILE);
        File bootLog = new File(dir, BOOT_LOG_FILE);
        if (errFile.isFile()) {
            sb.append(readSmallFile(errFile));
        } else if (bootLog.isFile()) {
            sb.append("Previous launch exited unexpectedly before the first frame.\n\n--- Boot log ---\n");
            sb.append(readSmallFile(bootLog));
        } else {
            sb.append("Previous launch exited unexpectedly before native startup completed.");
        }
        return sb.toString().trim();
    }

    private static String readSmallFile(File f) {
        try (InputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[Math.min((int) f.length(), 16 * 1024)];
            int n = in.read(buf);
            return n > 0 ? new String(buf, 0, n, StandardCharsets.UTF_8) : "";
        } catch (Exception e) {
            return "Failed reading " + f.getName() + ": " + e.getMessage();
        }
    }

    private static String joinLines(List<String> items) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) {
                sb.append("\n• ");
            }
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    private static void deleteQuietly(File f) {
        if (f != null && f.exists()) {
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
    }

    private String queryDisplayName(Uri uri) {
        try (Cursor c = getContentResolver().query(uri, new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                return c.getString(0);
            }
        } catch (Exception e) {
            Log.w(TAG, "queryDisplayName failed", e);
        }
        return uri.getLastPathSegment();
    }

    private int dp(int v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }
}
