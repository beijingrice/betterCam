package com.ppschool.bettercam.data

import android.content.Context
import android.content.SharedPreferences
import com.ppschool.bettercam.widget.ShutterWidgetProvider
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Port of ShutterManager: shutter counts shared with the home-screen widget. */
object ShutterCounter {
    const val PREFS_NAME = "bettercam_group"
    const val TOTAL_SHUTTER_KEY = "total_shutter"
    const val SESSION_KEY = "session_count"
    const val LAST_SS_KEY = "last_SS"
    const val LAST_ISO_KEY = "last_ISO"

    private var sessionCount = 0

    fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun todayKey(): String = "shutter_" + SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())

    @Synchronized
    fun increment(context: Context) {
        val p = prefs(context)
        val today = todayKey()
        sessionCount += 1
        p.edit()
            .putInt(TOTAL_SHUTTER_KEY, p.getInt(TOTAL_SHUTTER_KEY, 0) + 1)
            .putInt(today, p.getInt(today, 0) + 1)
            .putInt(SESSION_KEY, sessionCount)
            .apply()
        ShutterWidgetProvider.refreshAll(context)
    }

    fun cleanupOldData(context: Context) {
        val p = prefs(context)
        val today = todayKey()
        val stale = p.all.keys.filter { it.startsWith("shutter_") && it != today }
        if (stale.isNotEmpty()) p.edit().apply { stale.forEach { remove(it) } }.apply()
    }

    fun resetSession(context: Context) {
        sessionCount = 0
        prefs(context).edit().putInt(SESSION_KEY, 0).apply()
        ShutterWidgetProvider.refreshAll(context)
    }
}
