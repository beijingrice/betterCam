package com.ppschool.bettercam.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.ppschool.bettercam.MainActivity
import com.ppschool.bettercam.R
import com.ppschool.bettercam.data.ShutterCounter

/** BetterCamWidget.swift: shutter counts + last manual exposure, tap to launch. */
class ShutterWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, buildViews(context)) }
    }

    companion object {
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, ShutterWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = buildViews(context)
            ids.forEach { manager.updateAppWidget(it, views) }
        }

        private fun buildViews(context: Context): RemoteViews {
            val p = ShutterCounter.prefs(context)
            val total = p.getInt(ShutterCounter.TOTAL_SHUTTER_KEY, 0)
            val session = p.getInt(ShutterCounter.SESSION_KEY, 0)
            val ss = p.getString(ShutterCounter.LAST_SS_KEY, "AUTO") ?: "AUTO"
            val iso = p.getString(ShutterCounter.LAST_ISO_KEY, "AUTO") ?: "AUTO"
            return RemoteViews(context.packageName, R.layout.widget_shutter).apply {
                setTextViewText(R.id.widget_counts, "${total - session} -> $total")
                setTextViewText(R.id.widget_total, context.getString(R.string.widget_total, total))
                setTextViewText(
                    R.id.widget_exposure,
                    if (ss != "AUTO" && iso != "AUTO") "${ss}s $iso" else context.getString(R.string.full_auto_mode)
                )
                val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                setOnClickPendingIntent(
                    R.id.widget_root,
                    PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                )
            }
        }
    }
}
