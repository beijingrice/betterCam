package com.ppschool.bettercam

import android.Manifest
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.ppschool.bettercam.billing.StoreManager
import com.ppschool.bettercam.ui.BetterCamRoot

class MainActivity : ComponentActivity() {
    private val model: CameraModel by viewModels()
    private lateinit var store: StoreManager

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { model.onPermissionResult(it) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemBars()
        store = StoreManager(applicationContext)
        model.permissionRequester = { permissionLauncher.launch(Manifest.permission.CAMERA) }
        model.requestPermissionIfNeeded()
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                BetterCamRoot(model, store)
            }
        }
    }

    private fun hideSystemBars() {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    override fun onStart() {
        super.onStart()
        model.onForegroundChanged(true)
    }

    override fun onStop() {
        model.onForegroundChanged(false)
        super.onStop()
    }

    override fun onDestroy() {
        store.close()
        super.onDestroy()
    }

    /** Volume / camera keys trigger the shutter (AVCaptureEventInteraction on iOS). */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_CAMERA) {
            if (model.inCameraView && !model.isShowingMenu && !model.isShowingTutorial) {
                if (event.repeatCount == 0) model.takePhoto()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
