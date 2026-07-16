/*
 * Copyright (c) 2026 Helmut NeemanDigital contributors.
 * Use of this source code is governed by the GPL v3 license
 * that can be found in the LICENSE file.
 */
package de.neemann.gui;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Locale;
import java.util.Properties;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.prefs.Preferences;

/**
 * file backed replacement for {@link Preferences} used by Digital.
 *
 * <p>The original code stored every user setting in
 * {@code java.util.prefs.Preferences}, whose Windows backend writes to the
 * registry under {@code HKCU\Software\JavaSoft\Prefs\dig}. That made the
 * jpackage uninstaller unable to remove the residue, because the MSI only
 * deletes the files it installed itself.</p>
 *
 * <p>This class keeps all settings in a single {@code prefs.properties} file
 * placed in the OS specific user configuration directory:</p>
 * <ul>
 *   <li>Windows: {@code %APPDATA%\Digital}</li>
 *   <li>macOS: {@code ~/Library/Application Support/Digital}</li>
 *   <li>Linux and others: {@code $XDG_CONFIG_HOME/Digital} (default {@code ~/.config/Digital})</li>
 * </ul>
 *
 * <p>{@code node(name)} does not create a new backing store; it returns a view
 * whose keys are prefixed by the node path, so the whole tree lives in one
 * flat properties file. This mirrors the subset of the
 * {@link java.util.prefs.Preferences} API actually used by Digital.</p>
 *
 * <p>Mutations update an in-memory cache and mark it dirty. A daemon scheduler
 * performs a coalesced flush at most once per second so that frequent events
 * (window resizing) do not thrash the disk. A shutdown hook forces a final
 * synchronous flush on JVM exit. If the configuration directory cannot be
 * created or written, the store silently degrades to in-memory only and never
 * prevents the application from starting.</p>
 *
 * <p>On the first launch after switching to this implementation, the legacy
 * {@code Preferences.userRoot().node("dig")} subtree is migrated into the new
 * file once, and the legacy node is then removed best effort.</p>
 */
public final class Prefs {

    private static final String APP_NAME = "Digital";
    private static final String FILE_NAME = "prefs.properties";
    private static final String MIGRATED_FLAG = "prefs.migrated";
    private static final long FLUSH_DELAY_MILLIS = 1000L;

    /** Shared in-memory copy of the properties file. */
    private static final Properties STORE = new Properties();
    private static volatile boolean dirty = false;
    private static File file;
    private static File migratedMark;
    private static volatile boolean persistOk = true;

    private static final ScheduledExecutorService SCHEDULER =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "Digital-Prefs-Writer");
                t.setDaemon(true);
                return t;
            });
    private static ScheduledFuture<?> pendingFlush;

    static {
        try {
            File base = resolveBaseDir();
            if (base != null) {
                file = new File(base, FILE_NAME);
                migratedMark = new File(base, MIGRATED_FLAG);
                if (file.exists()) {
                    loadFile();
                }
            } else {
                persistOk = false;
            }
            migrateOnce();
        } catch (Throwable t) {
            // Never let preference handling break application startup.
            persistOk = false;
        }
        Runtime.getRuntime().addShutdownHook(new Thread(Prefs::forceFlush, "Digital-Prefs-Flush"));
    }

    private final String prefix;

    private Prefs(String prefix) {
        this.prefix = prefix;
    }

    /**
     * Root node, equivalent to {@link Preferences#userRoot()}.
     *
     * @return the root node
     */
    public static Prefs userRoot() {
        return new Prefs("");
    }

    /**
     * Returns a child node. The returned node shares the same backing file;
     * only its key prefix differs.
     *
     * @param name the child name
     * @return the child node
     */
    public Prefs node(String name) {
        if (name == null || name.length() == 0) {
            return this;
        }
        return new Prefs(prefix + name + "/");
    }

    /**
     * @return the absolute prefix of this node (for debugging only)
     */
    public String absolutePath() {
        return "/" + prefix.substring(0, Math.max(0, prefix.length() - 1));
    }

    // ---- string values ----------------------------------------------------

    /**
     * Returns the string value stored under {@code key}, or {@code def} if absent.
     *
     * @param key the key
     * @param def the default value returned when the key is not present
     * @return the stored value or the default
     */
    public String get(String key, String def) {
        synchronized (STORE) {
            String v = STORE.getProperty(prefix + key);
            return v != null ? v : def;
        }
    }

    /**
     * Stores a string value under {@code key}. A {@code null} value removes the key.
     *
     * @param key   the key
     * @param value the value to store, or {@code null} to remove the key
     */
    public void put(String key, String value) {
        if (key == null) {
            throw new NullPointerException();
        }
        if (value == null) {
            remove(key);
            return;
        }
        synchronized (STORE) {
            STORE.setProperty(prefix + key, value);
            dirty = true;
        }
        scheduleFlush();
    }

    /**
     * Removes the value stored under {@code key}, if any.
     *
     * @param key the key to remove
     */
    public void remove(String key) {
        synchronized (STORE) {
            Object prev = STORE.remove(prefix + key);
            if (prev != null) {
                dirty = true;
            }
        }
        scheduleFlush();
    }

    /**
     * Removes every key that belongs to this node.
     */
    public void clear() {
        synchronized (STORE) {
            boolean changed = false;
            for (String name : STORE.stringPropertyNames()) {
                if (name.startsWith(prefix)) {
                    STORE.remove(name);
                    changed = true;
                }
            }
            if (changed) {
                dirty = true;
            }
        }
        scheduleFlush();
    }

    /**
     * Returns the keys present in this node.
     *
     * @return a freshly allocated array of key names
     */
    public String[] keys() {
        synchronized (STORE) {
            java.util.List<String> result = new java.util.ArrayList<String>();
            int plen = prefix.length();
            for (String name : STORE.stringPropertyNames()) {
                if (name.startsWith(prefix)) {
                    result.add(name.substring(plen));
                }
            }
            return result.toArray(new String[0]);
        }
    }

    // ---- typed getters/setters -------------------------------------------

    /**
     * Returns the int stored under {@code key}, or {@code def} on miss/parse error.
     *
     * @param key the key
     * @param def the default value
     * @return the stored int or the default
     */
    public int getInt(String key, int def) {
        String v = get(key, null);
        if (v == null) {
            return def;
        }
        try {
            return Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    /**
     * Stores an int under {@code key}.
     *
     * @param key   the key
     * @param value the value
     */
    public void putInt(String key, int value) {
        put(key, Integer.toString(value));
    }

    /**
     * Returns the long stored under {@code key}, or {@code def} on miss/parse error.
     *
     * @param key the key
     * @param def the default value
     * @return the stored long or the default
     */
    public long getLong(String key, long def) {
        String v = get(key, null);
        if (v == null) {
            return def;
        }
        try {
            return Long.parseLong(v.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    /**
     * Stores a long under {@code key}.
     *
     * @param key   the key
     * @param value the value
     */
    public void putLong(String key, long value) {
        put(key, Long.toString(value));
    }

    /**
     * Returns the double stored under {@code key}, or {@code def} on miss/parse error.
     *
     * @param key the key
     * @param def the default value
     * @return the stored double or the default
     */
    public double getDouble(String key, double def) {
        String v = get(key, null);
        if (v == null) {
            return def;
        }
        try {
            return Double.parseDouble(v.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    /**
     * Stores a double under {@code key}.
     *
     * @param key   the key
     * @param value the value
     */
    public void putDouble(String key, double value) {
        put(key, Double.toString(value));
    }

    /**
     * Returns the boolean stored under {@code key}, or {@code def} on miss/parse error.
     *
     * @param key the key
     * @param def the default value
     * @return the stored boolean or the default
     */
    public boolean getBoolean(String key, boolean def) {
        String v = get(key, null);
        if (v == null) {
            return def;
        }
        String t = v.trim();
        if ("true".equalsIgnoreCase(t)) {
            return true;
        }
        if ("false".equalsIgnoreCase(t)) {
            return false;
        }
        return def;
    }

    /**
     * Stores a boolean under {@code key}.
     *
     * @param key   the key
     * @param value the value
     */
    public void putBoolean(String key, boolean value) {
        put(key, Boolean.toString(value));
    }

    // ---- persistence ------------------------------------------------------

    /**
     * Forces any pending change to be written to disk synchronously.
     */
    public static void flush() {
        forceFlush();
    }

    /**
     * Forces any pending change to be written to disk synchronously.
     */
    public static void sync() {
        forceFlush();
    }

    private static void scheduleFlush() {
        if (!persistOk) {
            return;
        }
        synchronized (STORE) {
            if (!dirty) {
                return;
            }
            if (pendingFlush == null || pendingFlush.isDone()) {
                pendingFlush = SCHEDULER.schedule(
                        Prefs::writeIfDirty,
                        FLUSH_DELAY_MILLIS,
                        TimeUnit.MILLISECONDS);
            }
        }
    }

    private static void forceFlush() {
        // Cancel pending coalesced write so we take over.
        synchronized (STORE) {
            if (pendingFlush != null) {
                pendingFlush.cancel(false);
                pendingFlush = null;
            }
        }
        writeIfDirty();
    }

    private static void writeIfDirty() {
        if (!persistOk || file == null) {
            return;
        }
        Properties snapshot;
        synchronized (STORE) {
            if (!dirty) {
                return;
            }
            snapshot = new Properties();
            snapshot.putAll(STORE);
            dirty = false;
        }
        try {
            File parent = file.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                persistOk = false;
                return;
            }
            try (OutputStream out = new FileOutputStream(file)) {
                snapshot.store(out, "Digital user preferences");
            }
        } catch (IOException e) {
            // Best effort: keep the in-memory state, try again on next flush.
        }
    }

    private static void loadFile() {
        try (InputStream in = new FileInputStream(file)) {
            STORE.load(in);
        } catch (IOException e) {
            // keep empty store
        }
    }

    /**
     * Resolves the OS specific configuration directory for Digital.
     *
     * @return the directory, or {@code null} if it cannot be determined
     */
    private static File resolveBaseDir() {
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        String base;
        if (os.contains("win")) {
            base = System.getenv("APPDATA");
            if (base == null || base.trim().length() == 0) {
                base = System.getProperty("user.home");
                if (base == null || base.trim().length() == 0) {
                    return null;
                }
            }
        } else if (os.contains("mac")) {
            base = System.getProperty("user.home");
            if (base == null || base.trim().length() == 0) {
                return null;
            }
            base = base + "/Library/Application Support";
        } else {
            base = System.getenv("XDG_CONFIG_HOME");
            if (base == null || base.trim().length() == 0) {
                base = System.getProperty("user.home");
                if (base == null || base.trim().length() == 0) {
                    return null;
                }
                base = base + "/.config";
            }
        }
        return new File(base, APP_NAME);
    }

    // ---- one time migration from java.util.prefs ------------------------

    private static void migrateOnce() {
        if (!persistOk || file == null || migratedMark == null) {
            return;
        }
        if (migratedMark.exists()) {
            return;
        }
        // Only migrate when the new file does not yet exist or is empty.
        boolean needMigration;
        synchronized (STORE) {
            needMigration = STORE.isEmpty();
        }
        if (!needMigration) {
            touchMigratedMark();
            return;
        }
        try {
            Preferences legacyRoot = Preferences.userRoot().node("dig");
            copyLegacy(legacyRoot, "dig/");
            synchronized (STORE) {
                dirty = !STORE.isEmpty();
            }
            if (dirty) {
                forceFlush();
            }
            try {
                Preferences.userRoot().node("dig").removeNode();
            } catch (Exception e) {
                // leftover registry entry stays; user can delete manually
            }
        } catch (Throwable t) {
            // migration is best effort
        }
        touchMigratedMark();
    }

    private static void copyLegacy(Preferences node, String keyPrefix) {
        try {
            String[] keys = node.keys();
            for (String k : keys) {
                String v = node.get(k, null);
                if (v != null) {
                    synchronized (STORE) {
                        STORE.setProperty(keyPrefix + k, v);
                    }
                }
            }
            for (String child : node.childrenNames()) {
                copyLegacy(node.node(child), keyPrefix + child + "/");
            }
        } catch (Exception e) {
            // best effort, continue with what we have
        }
    }

    private static void touchMigratedMark() {
        try {
            File parent = migratedMark.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                return;
            }
            if (!migratedMark.exists() && !migratedMark.createNewFile()) {
                return;
            }
        } catch (IOException e) {
            // ignore
        }
    }
}


