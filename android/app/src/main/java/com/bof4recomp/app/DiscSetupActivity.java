package com.bof4recomp.app;

import android.app.Activity;
import android.content.ClipData;
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

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Lightweight launcher & first-run disc importer.
 *
 * When a Breath of Fire IV disc image (.cue/.bin/.iso or disc/SLUS_013.24) is
 * already present in app storage, immediately forwards to Bof4Activity with
 * zero visible delay. Otherwise guides the player to pick their legal PS1 disc
 * dump using Android's Storage Access Framework (no storage permissions needed).
 */
public class DiscSetupActivity extends Activity {
    private static final String TAG = "DiscSetupActivity";
    private static final int REQ_PICK_DISC = 1001;

    private File dataDir;
    private TextView statusText;
    private ProgressBar progressBar;
    private Button pickButton;
    private Button retryButton;
    private final ExecutorService ioPool = Executors.newSingleThreadExecutor();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        dataDir = Bof4Activity.resolveDataDir(this);
        if (!dataDir.exists()) {
            dataDir.mkdirs();
        }

        if (hasDiscImage(dataDir)) {
            launchGame();
            return;
        }

        buildSetupUi();
    }

    @Override
    protected void onDestroy() {
        ioPool.shutdownNow();
        super.onDestroy();
    }

    public static boolean hasDiscImage(File dir) {
        if (dir == null || !dir.isDirectory()) {
            return false;
        }
        File[] files = dir.listFiles();
        if (files == null) {
            return false;
        }
        for (File f : files) {
            if (!f.isFile()) {
                continue;
            }
            String low = f.getName().toLowerCase(Locale.US);
            if (low.endsWith(".cue") || low.endsWith(".iso") || low.endsWith(".bin")) {
                return true;
            }
        }
        return false;
    }

    private void launchGame() {
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
        root.setGravity(Gravity.CENTER);
        int pad = dp(28);
        root.setPadding(pad, pad, pad, pad);

        TextView heading = new TextView(this);
        heading.setText(R.string.setup_heading);
        heading.setTextColor(Color.parseColor("#EAF1FF"));
        heading.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        heading.setTypeface(Typeface.DEFAULT_BOLD);
        heading.setGravity(Gravity.CENTER);
        root.addView(heading);

        TextView body = new TextView(this);
        body.setText(getString(R.string.setup_body, dataDir.getAbsolutePath()));
        body.setTextColor(Color.parseColor("#B4C0D6"));
        body.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        body.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams bodyLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        bodyLp.topMargin = dp(12);
        bodyLp.bottomMargin = dp(18);
        root.addView(body, bodyLp);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER);

        pickButton = new Button(this);
        pickButton.setText(R.string.setup_pick_button);
        pickButton.setAllCaps(false);
        pickButton.setTextColor(Color.WHITE);
        pickButton.setBackgroundColor(Color.parseColor("#3B6AD8"));
        pickButton.setPadding(dp(20), dp(12), dp(20), dp(12));
        pickButton.setOnClickListener(v -> openFilePicker());

        retryButton = new Button(this);
        retryButton.setText(R.string.setup_retry_button);
        retryButton.setAllCaps(false);
        retryButton.setTextColor(Color.parseColor("#DCE6FA"));
        retryButton.setBackgroundColor(Color.parseColor("#243047"));
        retryButton.setPadding(dp(20), dp(12), dp(20), dp(12));
        retryButton.setOnClickListener(v -> {
            if (hasDiscImage(dataDir)) {
                launchGame();
            } else {
                statusText.setText(R.string.setup_missing);
            }
        });

        LinearLayout.LayoutParams btnLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        btnLp.rightMargin = dp(12);
        buttons.addView(pickButton, btnLp);
        buttons.addView(retryButton);
        root.addView(buttons);

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setIndeterminate(true);
        progressBar.setVisibility(View.GONE);
        LinearLayout.LayoutParams pbLp = new LinearLayout.LayoutParams(
                dp(320), LinearLayout.LayoutParams.WRAP_CONTENT);
        pbLp.topMargin = dp(16);
        root.addView(progressBar, pbLp);

        statusText = new TextView(this);
        statusText.setTextColor(Color.parseColor("#8FA9D9"));
        statusText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        statusText.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams stLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        stLp.topMargin = dp(12);
        root.addView(statusText, stLp);

        scroll.addView(root);
        setContentView(scroll);
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
        if (uris.isEmpty()) {
            return;
        }
        importUris(uris);
    }

    private void importUris(List<Uri> uris) {
        pickButton.setEnabled(false);
        retryButton.setEnabled(false);
        progressBar.setVisibility(View.VISIBLE);

        ioPool.execute(() -> {
            byte[] buf = new byte[256 * 1024];
            for (Uri uri : uris) {
                String name = queryDisplayName(uri);
                if (name == null || name.isEmpty()) {
                    continue;
                }
                // Strip any path separators for safety.
                name = new File(name).getName();
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
                    runOnUiThread(() -> statusText.setText("Error copying " + finalName + ": " + e.getMessage()));
                }
            }
            runOnUiThread(() -> {
                progressBar.setVisibility(View.GONE);
                pickButton.setEnabled(true);
                retryButton.setEnabled(true);
                if (hasDiscImage(dataDir)) {
                    statusText.setText(R.string.setup_ready);
                    launchGame();
                } else {
                    statusText.setText(R.string.setup_missing);
                }
            });
        });
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
