package io.globules.videorecorder

import android.content.Intent
import android.os.Build
import android.util.Log
import org.apache.cordova.CallbackContext
import org.apache.cordova.CordovaPlugin
import org.apache.cordova.PluginResult
import org.json.JSONArray
import org.json.JSONObject

class VideoRecorder : CordovaPlugin() {

    private var currentCallback: CallbackContext? = null
    private var previewCallback: CallbackContext? = null

    // Shared by startRecording and startPreview. Hardcoded until setCamera() is called.
    private var camera: String = DEFAULT_CAMERA
    private var resolution: String = DEFAULT_RESOLUTION

    override fun execute(
        action: String,
        args: JSONArray,
        callbackContext: CallbackContext
    ): Boolean {
        return when (action) {
            "setCamera" -> {
                setCamera(args, callbackContext)
                true
            }
            "startRecording" -> {
                startRecording(args, callbackContext)
                true
            }
            "stopRecording" -> {
                stopRecording(callbackContext)
                true
            }
            "startPreview" -> {
                startPreview(args, callbackContext)
                true
            }
            "stopPreview" -> {
                stopPreview(callbackContext)
                true
            }
            "captureFrame" -> {
                captureFrame(callbackContext)
                true
            }
            else -> false
        }
    }

    private fun setCamera(args: JSONArray, callbackContext: CallbackContext) {
        val options = args.optJSONObject(0) ?: JSONObject()

        var nextCamera = camera
        var nextResolution = resolution

        if (options.has("camera")) {
            val cam = options.optString("camera", "").trim()
            if (!cam.equals("front", ignoreCase = true) && !cam.equals("back", ignoreCase = true)) {
                callbackContext.error("camera must be \"front\" or \"back\"")
                return
            }
            nextCamera = if (cam.equals("front", ignoreCase = true)) "front" else "back"
        }

        if (options.has("resolution")) {
            val parsed = parseResolution(options.optString("resolution", ""))
            if (parsed == null) {
                callbackContext.error("resolution must be WIDTHxHEIGHT")
                return
            }
            nextResolution = parsed
        }

        camera = nextCamera
        resolution = nextResolution

        Log.d("VideoRecorder", "setCamera camera=$camera resolution=$resolution")
        callbackContext.success()
    }

    private fun startRecording(args: JSONArray, callbackContext: CallbackContext) {
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        currentCallback = callbackContext

        val options: JSONObject = args.optJSONObject(0) ?: JSONObject()

        val bitrateRaw = if (options.has("bitrate")) options.optInt("bitrate", DEFAULT_BITRATE) else DEFAULT_BITRATE
        val maxLengthRaw = if (options.has("maxLength")) options.optInt("maxLength", DEFAULT_MAX_LENGTH) else DEFAULT_MAX_LENGTH
        val saveToGallery = if (options.has("saveToGallery")) options.optBoolean("saveToGallery", false) else false
        val bitrate = if (bitrateRaw > 0) bitrateRaw else DEFAULT_BITRATE
        val maxLength = if (maxLengthRaw > 0) maxLengthRaw else 0

        var watermarkEnabled = false
        var watermarkImage: String? = null
        var watermarkPosition = "bottomright"

        val wm: Any? = if (options.has("watermark")) options.opt("watermark") else null
        if (wm is JSONObject) {
            watermarkEnabled = true
            watermarkImage = if (wm.has("image")) wm.getString("image") else null
            watermarkPosition = wm.optString("position", "bottomright")
        }

        // CALLBACK FROM RecordingService
        RecordingService.stopWithCallback = { filePath: String?, videoWidth: Int?, videoHeight: Int? ->
            val safePath: String = filePath ?: ""
            val safeWidth: Int = videoWidth ?: 0
            val safeHeight: Int = videoHeight ?: 0

            val js = """
                document.dispatchEvent(new CustomEvent('VideoRecorderFinished', {
                    detail: { file: '$safePath', width: $safeWidth, height: $safeHeight }
                }));
            """.trimIndent()

            activity.runOnUiThread {
                webView.loadUrl("javascript:$js")
            }

            currentCallback?.success(safePath)
            currentCallback = null
        }

        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "START_RECORDING"
            putExtra("resolution", resolution)
            putExtra("bitrate", bitrate)
            putExtra("maxLength", maxLength)
            putExtra("camera", camera)
            putExtra("saveToGallery", saveToGallery)
            putExtra("watermarkEnabled", watermarkEnabled)
            putExtra("watermarkImage", watermarkImage)
            putExtra("watermarkPosition", watermarkPosition)
        }

        activity.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent)
            } else {
                activity.startService(intent)
            }
        }
    }

    private fun stopRecording(callbackContext: CallbackContext) {
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "STOP_RECORDING"
        }

        activity.startService(intent)
        callbackContext.success()
    }

    /**
     * Start preview. Camera and resolution come from setCamera().
     * Options: { scale, fps, quality } with hardcoded fallbacks.
     */
    private fun startPreview(args: JSONArray, callbackContext: CallbackContext) {
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        val options = args.optJSONObject(0) ?: JSONObject()
        val fpsRaw = if (options.has("fps")) options.optInt("fps", DEFAULT_FPS) else DEFAULT_FPS
        val qualityRaw = if (options.has("quality")) options.optInt("quality", DEFAULT_QUALITY) else DEFAULT_QUALITY
        val scaleRaw = if (options.has("scale")) options.optDouble("scale", DEFAULT_SCALE.toDouble()) else DEFAULT_SCALE.toDouble()

        val fps = if (fpsRaw > 0) fpsRaw else DEFAULT_FPS
        val quality = if (qualityRaw in 1..100) qualityRaw else DEFAULT_QUALITY
        val scale = if (scaleRaw > 0.0) scaleRaw.toFloat() else DEFAULT_SCALE

        previewCallback = callbackContext

        val startResult = PluginResult(PluginResult.Status.OK, "preview_started")
        startResult.keepCallback = true
        try {
            Log.d("VideoRecorder", "startPreview: camera=$camera resolution=$resolution scale=$scale fps=$fps quality=$quality")
            previewCallback?.sendPluginResult(startResult)
        } catch (e: Exception) {
            previewCallback = null
            callbackContext.error("Failed to register preview callback: ${e.message}")
            return
        }

        val act = cordova.activity

        RecordingService.previewFrameCallback = fun(base64Frame: String) {
            try {
                val currentAct = act
                if (currentAct == null || currentAct.isFinishing ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && currentAct.isDestroyed)
                ) {
                    Log.w("VideoRecorder", "preview lambda: activity gone, clearing callback")
                    RecordingService.previewFrameCallback = null
                    previewCallback = null
                    return
                }

                Log.v("VideoRecorder", "preview lambda: forwarding frame to JS (len=${base64Frame.length})")
                val frameResult = PluginResult(PluginResult.Status.OK, base64Frame)
                frameResult.keepCallback = true
                previewCallback?.sendPluginResult(frameResult)
            } catch (ex: Exception) {
                Log.w("VideoRecorder", "preview lambda: sendPluginResult failed: ${ex.message}")
                RecordingService.previewFrameCallback = null
                previewCallback = null

                try {
                    val currentAct = act
                    if (currentAct != null) {
                        val stopIntent = Intent(currentAct, RecordingService::class.java).apply {
                            action = "STOP_PREVIEW"
                        }
                        currentAct.runOnUiThread {
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    currentAct.startForegroundService(stopIntent)
                                } else {
                                    currentAct.startService(stopIntent)
                                }
                            } catch (_: Exception) { /* ignore */ }
                        }
                    }
                } catch (_: Exception) { /* ignore */ }
            }
        }

        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "START_PREVIEW"
            putExtra("camera", camera)
            putExtra("resolution", resolution)
            putExtra("fps", fps)
            putExtra("quality", quality)
            putExtra("scale", scale)
        }

        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    activity.startForegroundService(intent)
                } else {
                    activity.startService(intent)
                }
            } catch (e: Exception) {
                RecordingService.previewFrameCallback = null
                previewCallback = null
                try {
                    callbackContext.error("Failed to start preview service: ${e.message}")
                } catch (_: Exception) {}
            }
        }
    }

    private fun stopPreview(callbackContext: CallbackContext) {
        RecordingService.previewFrameCallback = null

        val stopResult = PluginResult(PluginResult.Status.OK, "preview_stopped")
        stopResult.keepCallback = false
        try {
            callbackContext.sendPluginResult(stopResult)
        } catch (_: Exception) { /* ignore */ }

        previewCallback = null

        val activity = cordova.activity ?: return
        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "STOP_PREVIEW"
        }
        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    activity.startForegroundService(intent)
                } else {
                    activity.startService(intent)
                }
            } catch (_: Exception) { /* ignore */ }
        }
    }

    /**
     * One still at the setCamera resolution. Preview must already be running.
     * Success is "data:image/jpeg;base64,...".
     */
    private fun captureFrame(callbackContext: CallbackContext) {
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        if (RecordingService.captureFrameCallback != null) {
            callbackContext.error("capture already in progress")
            return
        }

        RecordingService.captureFrameCallback = callback@{ image, error ->
            val current = cordova.activity ?: return@callback
            current.runOnUiThread {
                if (error != null) callbackContext.error(error)
                else callbackContext.success(image ?: "")
            }
        }

        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "CAPTURE_FRAME"
        }
        try {
            activity.startService(intent)
        } catch (e: Exception) {
            RecordingService.captureFrameCallback = null
            callbackContext.error("Failed to capture frame: ${e.message}")
        }
    }

    private fun requestStopPreviewFromPlugin() {
        val act = cordova.activity ?: return
        try {
            val stopIntent = Intent(act, RecordingService::class.java).apply {
                action = "STOP_PREVIEW"
            }
            act.runOnUiThread {
            try {
                act.startService(stopIntent)
            } catch (_: Exception) {}
        }
        } catch (_: Exception) {}
    }

    private fun requestStopRecordingFromPlugin() {
        val act = cordova.activity ?: return
        try {
            val stopIntent = Intent(act, RecordingService::class.java).apply {
                action = "STOP_RECORDING"
            }
            act.runOnUiThread {
            try {
                act.startService(stopIntent)
            } catch (_: Exception) {}
        }
        } catch (_: Exception) {}
    }

    override fun onPause(multitasking: Boolean) {
        super.onPause(multitasking)
        requestStopPreviewFromPlugin()
    }

    override fun onDestroy() {
        super.onDestroy()
        requestStopPreviewFromPlugin()
        requestStopRecordingFromPlugin()
    }

    private fun parseResolution(value: String): String? {
        val parts = value.trim().lowercase().split("x")
        if (parts.size != 2) return null
        val w = parts[0].toIntOrNull()
        val h = parts[1].toIntOrNull()
        if (w == null || h == null || w <= 0 || h <= 0) return null
        return "${w}x${h}"
    }

    companion object {
        private const val DEFAULT_CAMERA = "back"
        private const val DEFAULT_RESOLUTION = "1920x1080"
        private const val DEFAULT_BITRATE = 10_000_000
        private const val DEFAULT_MAX_LENGTH = 0
        private const val DEFAULT_FPS = 10
        private const val DEFAULT_QUALITY = 40
        private const val DEFAULT_SCALE = 0.3f
    }
}
