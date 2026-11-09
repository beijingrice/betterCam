package com.ppschool.bettercam.camera

import android.os.Process
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicInteger

/** Photo development runs below the UI / preview threads so the viewfinder never stalls. */
object BackgroundThreads {
    // Slightly below normal. THREAD_PRIORITY_BACKGROUND would also move the threads into the
    // background cgroup (little cores only), which made RAW development ~5x slower.
    private const val PRIORITY = Process.THREAD_PRIORITY_DEFAULT + 4

    fun factory(name: String): ThreadFactory {
        val n = AtomicInteger()
        return ThreadFactory { r ->
            Thread({
                Process.setThreadPriority(PRIORITY)
                r.run()
            }, "$name-${n.incrementAndGet()}")
        }
    }
}
