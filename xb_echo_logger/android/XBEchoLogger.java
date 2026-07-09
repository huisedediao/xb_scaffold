package com.xb.echo.logger;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Android 原生端 Echo 日志上报组件。
 *
 * 提供与 Dart 端对等的队列 + HTTP 上报能力，
 * 可在原生代码中直接调用，无需通过 Flutter MethodChannel。
 *
 * 使用方式：
 * <pre>{@code
 * // 初始化（在 Application.onCreate 中）
 * XBEchoLogger.init(context, "http://144.168.61.190:3000", "com.example.app", false);
 *
 * // 上报日志
 * JSONObject info = new JSONObject();
 * info.put("content", "用户点击了按钮");
 * XBEchoLogger.getInstance().echo(info);
 *
 * // 错误上报
 * XBEchoLogger.getInstance().err(info);
 * }</pre>
 */
public class XBEchoLogger {

    private static final String TAG = "XBEchoLogger";
    private static final String PREFS_NAME = "xb_echo_logger_prefs";
    private static final String KEY_QUEUE = "xb_echo_logger_queue";
    private static final String KEY_DEDUP = "xb_echo_logger_error_dedup";
    private static final int MAX_QUEUE_SIZE = 1000;
    private static final long START_DELAY_MS = 2000;
    private static final int REQUEST_TIMEOUT_MS = 3000;

    private static volatile XBEchoLogger sInstance;

    private Context mContext;
    private String mEchoHost;
    private String mAppId;
    private boolean mIsDebug;

    private final List<JSONObject> mQueue = new CopyOnWriteArrayList<>();
    private final List<Integer> mDedupHashes = new ArrayList<>();
    private volatile boolean mCanExecute = false;
    private final Handler mHandler;
    private final HandlerThread mHandlerThread;

    private XBEchoLogger() {
        mHandlerThread = new HandlerThread("XBEchoLogger");
        mHandlerThread.start();
        mHandler = new Handler(mHandlerThread.getLooper());
    }

    // ---- 初始化 ----

    /**
     * 初始化组件，应在 Application.onCreate() 中尽早调用。
     */
    public static void init(Context context, String echoHost, String appId, boolean isDebug) {
        if (sInstance == null) {
            synchronized (XBEchoLogger.class) {
                if (sInstance == null) {
                    sInstance = new XBEchoLogger();
                    sInstance.mContext = context.getApplicationContext();
                    sInstance.mEchoHost = echoHost;
                    sInstance.mAppId = appId;
                    sInstance.mIsDebug = isDebug;
                    sInstance.setup();
                }
            }
        }
    }

    public static XBEchoLogger getInstance() {
        if (sInstance == null) {
            throw new IllegalStateException("XBEchoLogger not initialized. Call init() first.");
        }
        return sInstance;
    }

    // ---- Setup ----

    private void setup() {
        SharedPreferences prefs = mContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

        // 恢复队列
        String queueJson = prefs.getString(KEY_QUEUE, null);
        if (queueJson != null && !queueJson.isEmpty()) {
            try {
                JSONArray arr = new JSONArray(queueJson);
                for (int i = 0; i < arr.length(); i++) {
                    mQueue.add(arr.getJSONObject(i));
                }
            } catch (JSONException e) {
                Log.e(TAG, "Failed to restore queue: " + e.getMessage());
            }
        }

        // 恢复去重列表
        String dedupStr = prefs.getString(KEY_DEDUP, null);
        if (dedupStr != null && !dedupStr.isEmpty()) {
            for (String part : dedupStr.split(",")) {
                try {
                    mDedupHashes.add(Integer.parseInt(part));
                } catch (NumberFormatException ignored) {
                }
            }
        }

        // 延迟启动
        mHandler.postDelayed(() -> {
            mCanExecute = true;
            processQueue();
        }, START_DELAY_MS);
    }

    // ---- Public API ----

    /**
     * 上报普通日志（走队列）。
     */
    public void echo(JSONObject info) {
        mHandler.post(() -> {
            if (mQueue.size() >= MAX_QUEUE_SIZE) {
                mQueue.remove(0);
            }
            mQueue.add(info);
            saveQueue();
            processQueue();
        });
    }

    /**
     * 上报错误日志（直接发送，带去重）。
     */
    public void err(JSONObject info) {
        mHandler.post(() -> {
            // 去重
            try {
                String content = info.optString("content", "");
                String hashStr = content + mAppId
                        + (mIsDebug ? "debug" : "release")
                        + info.optString("userId", "")
                        + info.optString("device", "")
                        + info.optString("systemVersion", "");
                int hashValue = hashStr.hashCode();

                if (mDedupHashes.contains(hashValue)) return;

                mDedupHashes.add(hashValue);
                if (mDedupHashes.size() > 1000) {
                    mDedupHashes.remove(0);
                }
                saveDedupList();
            } catch (Exception e) {
                Log.e(TAG, "err dedup error: " + e.getMessage());
            }

            // 延迟 1 秒发送
            mHandler.postDelayed(() -> {
                postDirectly(info, "/errCatch");
            }, 1000);
        });
    }

    /**
     * 直接发送（不经过队列）。
     */
    public void postDirectly(JSONObject info, String path) {
        String urlStr = mEchoHost + path;
        HttpURLConnection conn = null;
        try {
            URL url = new URL(urlStr);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(REQUEST_TIMEOUT_MS);
            conn.setReadTimeout(REQUEST_TIMEOUT_MS);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setDoOutput(true);

            OutputStream os = conn.getOutputStream();
            os.write(info.toString().getBytes("UTF-8"));
            os.flush();
            os.close();

            int code = conn.getResponseCode();
            if (code != 200) {
                Log.w(TAG, "POST " + path + " returned " + code);
            }
        } catch (IOException e) {
            Log.e(TAG, "POST " + path + " failed: " + e.getMessage());
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    /**
     * 当前队列待发送数量。
     */
    public int getPendingCount() {
        return mQueue.size();
    }

    // ---- Queue Processing ----

    private void processQueue() {
        if (mQueue.isEmpty()) return;
        if (!mCanExecute) return;

        mCanExecute = false;
        JSONObject info = mQueue.remove(0);
        saveQueue();

        String urlStr = mEchoHost + "/echo";
        boolean success = false;
        HttpURLConnection conn = null;
        try {
            URL url = new URL(urlStr);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(REQUEST_TIMEOUT_MS);
            conn.setReadTimeout(REQUEST_TIMEOUT_MS);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setDoOutput(true);

            OutputStream os = conn.getOutputStream();
            os.write(info.toString().getBytes("UTF-8"));
            os.flush();
            os.close();

            success = conn.getResponseCode() == 200;
        } catch (IOException e) {
            Log.e(TAG, "processQueue send failed: " + e.getMessage());
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }

        mCanExecute = true;
        processQueue();
    }

    // ---- Persistence ----

    private void saveQueue() {
        JSONArray arr = new JSONArray();
        for (JSONObject obj : mQueue) {
            arr.put(obj);
        }
        mContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_QUEUE, arr.toString())
                .apply();
    }

    private void saveDedupList() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < mDedupHashes.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append(mDedupHashes.get(i));
        }
        mContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_DEDUP, sb.toString())
                .apply();
    }
}
