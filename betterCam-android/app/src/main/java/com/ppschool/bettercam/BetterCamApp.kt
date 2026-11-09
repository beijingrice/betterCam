package com.ppschool.bettercam

import android.app.Application
import com.ppschool.bettercam.data.ShutterCounter
import com.ppschool.bettercam.engine.FilmEngine

class BetterCamApp : Application() {
    override fun onCreate() {
        super.onCreate()
        FilmEngine.init(this)
        ShutterCounter.cleanupOldData(this)
        ShutterCounter.resetSession(this)
    }
}
