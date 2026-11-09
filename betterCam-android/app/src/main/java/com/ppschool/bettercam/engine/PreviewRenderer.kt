package com.ppschool.bettercam.engine

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.random.Random

/**
 * Renders the camera stream into the viewfinder TextureView with the film look applied
 * (GLES2: OES camera texture + 3D LUT packed as a 2D atlas + procedural grain).
 * Also samples small frames for the waveform / histogram / manual light meter,
 * which replaces MetalWHProcessor on iOS.
 */
class PreviewRenderer(private val listener: Listener) {

    interface Listener {
        fun onCameraSurfaceReady(texture: SurfaceTexture)
        fun onAnalysisFrame(rgba: ByteBuffer, width: Int, height: Int)
    }

    data class Params(
        val plan: FilmEngine.Plan = FilmEngine.Plan(null, 0f, 0f),
        val turns: Int = 0,
        val analyze: Boolean = false,
        val libraryVersion: Int = 0,
    )

    @Volatile var params = Params()

    private val thread = HandlerThread("bettercam.gl").apply { start() }
    private val handler = Handler(thread.looper)

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowW = 0
    private var windowH = 0

    private var oesTex = 0
    private var cameraTexture: SurfaceTexture? = null
    @Volatile private var bufferW = 4
    @Volatile private var bufferH = 3

    private var program = 0
    private var analysisProgram = 0
    private val stMatrix = FloatArray(16)
    private val texMatrix = FloatArray(16)
    private val rotMatrix = FloatArray(16)
    private val lutTextures = HashMap<String, Int>()
    private var lutVersion = -1

    private var fbo = 0
    private var fboTex = 0
    private val analysisW = 128
    private val analysisH = 96
    private val analysisBuf: ByteBuffer =
        ByteBuffer.allocateDirect(analysisW * analysisH * 4).order(ByteOrder.nativeOrder())
    private var lastAnalysis = 0L

    private val quad: FloatBuffer = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder())
        .asFloatBuffer().apply {
            put(floatArrayOf(-1f, -1f, 0f, 0f, 1f, -1f, 1f, 0f, -1f, 1f, 0f, 1f, 1f, 1f, 1f, 1f)); position(0)
        }

    init {
        handler.post { setupEgl() }
    }

    fun setBufferSize(width: Int, height: Int) {
        bufferW = width
        bufferH = height
    }

    fun attachWindow(surface: SurfaceTexture, width: Int, height: Int) {
        handler.post {
            releaseWindow()
            try {
                window = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
                windowW = width; windowH = height
            } catch (e: Exception) {
                Log.e(TAG, "window surface failed", e)
                window = EGL14.EGL_NO_SURFACE
            }
        }
    }

    fun resizeWindow(width: Int, height: Int) {
        handler.post { windowW = width; windowH = height }
    }

    /** Blocks until the GL thread no longer touches the TextureView surface. */
    fun detachWindow() {
        val latch = CountDownLatch(1)
        handler.post { releaseWindow(); latch.countDown() }
        latch.await(1, TimeUnit.SECONDS)
    }

    fun release() {
        handler.post {
            releaseWindow()
            cameraTexture?.release()
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroySurface(display, pbuffer)
                EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            }
            thread.quitSafely()
        }
    }

    private fun releaseWindow() {
        if (window != EGL14.EGL_NO_SURFACE) {
            EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
            EGL14.eglDestroySurface(display, window)
            window = EGL14.EGL_NO_SURFACE
        }
    }

    // ------------------------------------------------------------------ setup

    private fun setupEgl() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(display, version, 0, version, 1)
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val num = IntArray(1)
        EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, num, 0)
        config = configs[0]
        context = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
        )
        pbuffer = EGL14.eglCreatePbufferSurface(
            display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0
        )
        EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)

        program = buildProgram(VERTEX, FRAGMENT)
        analysisProgram = buildProgram(VERTEX, FRAGMENT_PLAIN)

        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        oesTex = tex[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        setupFbo()

        val st = SurfaceTexture(oesTex)
        st.setOnFrameAvailableListener({ onFrame() }, handler)
        cameraTexture = st
        listener.onCameraSurfaceReady(st)
    }

    private fun setupFbo() {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        fboTex = ids[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTex)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, analysisW, analysisH, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glGenFramebuffers(1, ids, 0)
        fbo = ids[0]
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, fboTex, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    }

    // ------------------------------------------------------------------ frames

    private fun onFrame() {
        val st = cameraTexture ?: return
        val target = if (window != EGL14.EGL_NO_SURFACE) window else pbuffer
        if (!EGL14.eglMakeCurrent(display, target, target, context)) {
            releaseWindow()
            EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
        }
        try {
            st.updateTexImage()
        } catch (e: Exception) {
            return
        }
        st.getTransformMatrix(stMatrix)
        val p = params

        val now = SystemClock.uptimeMillis()
        if (p.analyze && now - lastAnalysis >= 120) {
            lastAnalysis = now
            drawAnalysis(p.turns)
        }
        if (window != EGL14.EGL_NO_SURFACE && windowW > 0 && windowH > 0) {
            drawPreview(p)
            if (!EGL14.eglSwapBuffers(display, window)) releaseWindow()
        }
    }

    private fun buildTexMatrix(turns: Int) {
        Matrix.setIdentityM(rotMatrix, 0)
        val step = floatArrayOf(0f, -1f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 1f)
        val tmp = FloatArray(16)
        repeat(((turns % 4) + 4) % 4) {
            Matrix.multiplyMM(tmp, 0, rotMatrix, 0, step, 0)
            System.arraycopy(tmp, 0, rotMatrix, 0, 16)
        }
        Matrix.multiplyMM(texMatrix, 0, stMatrix, 0, rotMatrix, 0)
    }

    private fun drawPreview(p: Params) {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, windowW, windowH)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        buildTexMatrix(p.turns)

        // Aspect fit (scaledToFit on iOS).
        val transposed = abs(stMatrix[0]) < 0.5f
        var contentAspect = if (transposed) bufferH.toFloat() / bufferW else bufferW.toFloat() / bufferH
        if (p.turns % 2 != 0) contentAspect = 1f / contentAspect
        val viewAspect = windowW.toFloat() / windowH
        val sx: Float
        val sy: Float
        if (contentAspect > viewAspect) { sx = 1f; sy = viewAspect / contentAspect } else { sx = contentAspect / viewAspect; sy = 1f }

        GLES20.glUseProgram(program)
        bindQuad(program)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTexMatrix"), 1, false, texMatrix, 0)
        GLES20.glUniform2f(GLES20.glGetUniformLocation(program, "uScale"), sx, sy)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uCam"), 0)

        val sim = p.plan.sim
        val lutTex = sim?.let { lutTexture(it, p.libraryVersion) } ?: 0
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, lutTex)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uLut"), 1)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uLutSize"), (sim?.dimension ?: 2).toFloat())
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uLutOn"), if (lutTex != 0) 1f else 0f)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uLutLinear"), if (sim?.linearInput == true) 1f else 0f)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uIntensity"), p.plan.intensity)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uGrain"), p.plan.grain)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(program, "uSeed"), Random.nextFloat() * 100f)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun drawAnalysis(turns: Int) {
        buildTexMatrix(turns)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glViewport(0, 0, analysisW, analysisH)
        GLES20.glUseProgram(analysisProgram)
        bindQuad(analysisProgram)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(analysisProgram, "uTexMatrix"), 1, false, texMatrix, 0)
        GLES20.glUniform2f(GLES20.glGetUniformLocation(analysisProgram, "uScale"), 1f, 1f)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(analysisProgram, "uCam"), 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        analysisBuf.position(0)
        GLES20.glReadPixels(0, 0, analysisW, analysisH, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, analysisBuf)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        analysisBuf.position(0)
        listener.onAnalysisFrame(analysisBuf, analysisW, analysisH)
    }

    private fun bindQuad(prog: Int) {
        val aPos = GLES20.glGetAttribLocation(prog, "aPos")
        val aUV = GLES20.glGetAttribLocation(prog, "aUV")
        quad.position(0)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(aPos)
        quad.position(2)
        GLES20.glVertexAttribPointer(aUV, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(aUV)
    }

    private fun lutTexture(sim: FilmSimulation, version: Int): Int {
        if (version != lutVersion) {
            lutTextures.values.forEach { GLES20.glDeleteTextures(1, intArrayOf(it), 0) }
            lutTextures.clear()
            lutVersion = version
        }
        lutTextures[sim.id]?.let { return it }
        val n = sim.dimension
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0])
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, n * n, n, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, FilmEngine.atlasBytes(sim))
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        lutTextures[sim.id] = ids[0]
        return ids[0]
    }

    private fun buildProgram(vs: String, fs: String): Int {
        fun compile(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) Log.e(TAG, "shader: " + GLES20.glGetShaderInfoLog(s))
            return s
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, compile(GLES20.GL_VERTEX_SHADER, vs))
        GLES20.glAttachShader(p, compile(GLES20.GL_FRAGMENT_SHADER, fs))
        GLES20.glLinkProgram(p)
        return p
    }

    companion object {
        private const val TAG = "PreviewRenderer"

        private const val VERTEX = """
            attribute vec2 aPos;
            attribute vec2 aUV;
            uniform mat4 uTexMatrix;
            uniform vec2 uScale;
            varying vec2 vTex;
            void main() {
                gl_Position = vec4(aPos * uScale, 0.0, 1.0);
                vTex = (uTexMatrix * vec4(aUV, 0.0, 1.0)).xy;
            }
        """

        private const val FRAGMENT_PLAIN = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uCam;
            varying vec2 vTex;
            void main() { gl_FragColor = vec4(texture2D(uCam, vTex).rgb, 1.0); }
        """

        private const val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #else
            precision mediump float;
            #endif
            uniform samplerExternalOES uCam;
            uniform sampler2D uLut;
            uniform float uLutSize;
            uniform float uLutOn;
            uniform float uLutLinear;
            uniform float uIntensity;
            uniform float uGrain;
            uniform float uSeed;
            varying vec2 vTex;

            vec3 toLin(vec3 c) {
                return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
            }
            vec3 toSrgb(vec3 c) {
                c = clamp(c, 0.0, 1.0);
                return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
            }
            vec3 lut(vec3 c) {
                float n = uLutSize;
                float b = c.b * (n - 1.0);
                float b0 = floor(b);
                float b1 = min(b0 + 1.0, n - 1.0);
                float f = b - b0;
                float x = c.r * (n - 1.0) + 0.5;
                float y = (c.g * (n - 1.0) + 0.5) / n;
                vec3 s0 = texture2D(uLut, vec2((b0 * n + x) / (n * n), y)).rgb;
                vec3 s1 = texture2D(uLut, vec2((b1 * n + x) / (n * n), y)).rgb;
                return mix(s0, s1, f);
            }
            float hash(vec2 p) {
                vec3 p3 = fract(vec3(p.xyx) * 0.1031 + uSeed);
                p3 += dot(p3, p3.yzx + 33.33);
                return fract((p3.x + p3.y) * p3.z);
            }
            float softLight(float b, float s) {
                if (s <= 0.5) return b - (1.0 - 2.0 * s) * b * (1.0 - b);
                float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
                return b + (2.0 * s - 1.0) * (d - b);
            }
            void main() {
                vec3 src = clamp(texture2D(uCam, vTex).rgb, 0.0, 1.0);
                vec3 col = src;
                if (uLutOn > 0.5) {
                    vec3 inp = uLutLinear > 0.5 ? toLin(src) : src;
                    vec3 f = lut(clamp(inp, 0.0, 1.0));
                    if (uLutLinear > 0.5) f = toSrgb(f);
                    col = mix(src, f, uIntensity);
                }
                if (uGrain > 0.0) {
                    float n = hash(gl_FragCoord.xy);
                    float g = ((n - 0.5) * (0.8 + uGrain * 0.15) + 0.5) * 0.4 + 0.3;
                    float gray = dot(col, vec3(0.2126, 0.7152, 0.0722));
                    float mask = clamp(gray + 0.6 + 0.12 + uGrain * 0.3, 0.0, 1.0);
                    vec3 soft = vec3(softLight(col.r, g), softLight(col.g, g), softLight(col.b, g));
                    col = mix(col, soft, mask);
                }
                gl_FragColor = vec4(col, 1.0);
            }
        """
    }
}
