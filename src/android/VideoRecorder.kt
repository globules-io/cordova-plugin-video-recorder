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

    override fun execute(
        action: String,
        args: JSONArray,
        callbackContext: CallbackContext
    ): Boolean {
        return when (action) {
            "start" -> {
                startRecording(args, callbackContext)
                true
            }
            "stop" -> {
                stopRecording(callbackContext)
                true
            }
            "preview" -> {
                // Accept either:
                // - an options object (JSONObject) as first arg -> start preview with options
                // - a boolean as first arg -> start/stop preview (backwards compatible)
                if (args.length() > 0 && args.optJSONObject(0) != null) {
                    val opts = args.optJSONObject(0)!!
                    handlePreviewWithOptions(opts, callbackContext)
                } else {
                    val enable = if (args.length() > 0) args.optBoolean(0, false) else false
                    if (enable) {
                        // boolean true ? start with sensible higher-quality defaults
                        val defaults = JSONObject().apply {
                            put("camera", "back")
                            put("resolution", "1280x720")   // better default than service fallback
                            put("fps", 15)
                        }
                        handlePreviewWithOptions(defaults, callbackContext)
                    } else {
                        handlePreview(false, callbackContext)
                    }
                }
                true
            }
            else -> false
        }
    }

    private fun startRecording(args: JSONArray, callbackContext: CallbackContext) {
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        currentCallback = callbackContext

        val options: JSONObject = if (args.length() > 0 && args.optJSONObject(0) != null) {
            args.optJSONObject(0)!!
        } else {
            JSONObject()
        }

        val resolution = options.optString("resolution", "1920x1080")
        val bitrate = options.optInt("bitrate", 10_000_000)
        val maxLength = options.optInt("maxLength", 0)
        val camera = options.optString("camera", "back")
        val saveToGallery = options.optBoolean("saveToGallery", false)

        // WATERMARK OPTIONS
        var watermarkEnabled = false
        var watermarkImage: String? = null
        var watermarkPosition = "bottomright"

        val wm: Any? = options.opt("watermark")
        if (wm is JSONObject) {
            watermarkEnabled = true
            watermarkImage = if (wm.has("image")) wm.getString("image") else null
            watermarkPosition = wm.optString("position", "bottomright")
        }

        // CALLBACK FROM RecordingService
        RecordingService.stopWithCallback = { filePath: String? ->
            val safePath: String = filePath ?: ""

            val js = """
                document.dispatchEvent(new CustomEvent('VideoRecorderFinished', {
                    detail: { file: '$safePath' }
                }));
            """.trimIndent()

            activity.runOnUiThread {
                webView.loadUrl("javascript:$js")
            }

            currentCallback?.success(safePath)
            currentCallback = null
        }

        // START SERVICE WITH ALL OPTIONS (recording path is completely independent)
        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "START_RECORDING"
            putExtra("resolution", resolution)
            putExtra("bitrate", bitrate)
            putExtra("maxLength", maxLength)
            putExtra("camera", camera)
            putExtra("saveToGallery", saveToGallery)

            // WATERMARK EXTRAS
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

    private fun handlePreview(enable: Boolean, callbackContext: CallbackContext) {
        if (enable) {
            // Should not reach here any more (boolean true is converted to options path),
            // but keep for safety.
            val defaults = JSONObject().apply {
                put("camera", "back")
                put("resolution", "1280x720")
                put("fps", 15)
            }
            handlePreviewWithOptions(defaults, callbackContext)
            return
        }

        // stop preview
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
     * Start preview using an options object (independent from recording options):
     * {
     *   camera: "front"|"back",
     *   resolution: "1280x720" | "1920x1080" | ...,
     *   fps: 10 | 15 | 30
     * }
     *
     * Preview resolution/fps are completely separate from the values used by start().
     */
    private fun handlePreviewWithOptions(options: JSONObject, callbackContext: CallbackContext) {
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        // Register the Cordova callback first
        previewCallback = callbackContext

        val startResult = PluginResult(PluginResult.Status.OK, "preview_started")
        startResult.keepCallback = true
        try {
            Log.d("VideoRecorder", "handlePreviewWithOptions: sending preview_started and keeping callback")
            previewCallback?.sendPluginResult(startResult)
        } catch (e: Exception) {
            previewCallback = null
            callbackContext.error("Failed to register preview callback: ${e.message}")
            return
        }

        val act = cordova.activity

        // Service-side lambda that forwards frames to JS
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

        // Independent preview options (never touch recording extras)
        val camera = options.optString("camera", "back")
        // Higher-quality defaults so preview looks better out of the box
        val resolution = options.optString("resolution", "1280x720")
        val fps = options.optInt("fps", 15)

        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "START_PREVIEW"
            putExtra("camera", camera)
            putExtra("resolution", resolution)
            putExtra("fps", fps)
            // Optional future knobs the service can honour
            putExtra("previewQuality", options.optString("quality", "high"))
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
}