package io.globules.videorecorder

import android.content.Intent
import android.os.Build
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
                    val opts = args.optJSONObject(0)
                    handlePreviewWithOptions(opts, callbackContext)
                } else {
                    val enable = if (args.length() > 0) args.optBoolean(0, false) else false
                    handlePreview(enable, callbackContext) // existing boolean path
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
            args.optJSONObject(0)
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

        // START SERVICE WITH ALL OPTIONS
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
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        if (enable) {
            // register the Cordova callback first
            previewCallback = callbackContext

            val startResult = org.apache.cordova.PluginResult(org.apache.cordova.PluginResult.Status.OK, "preview_started")
            startResult.keepCallback = true
            try {
                android.util.Log.d("VideoRecorder", "handlePreview: sending preview_started and keeping callback")
                previewCallback?.sendPluginResult(startResult)
            } catch (e: Exception) {
                previewCallback = null
                callbackContext.error("Failed to register preview callback: ${e.message}")
                return
            }

            // capture activity reference for use inside the lambda
            val act = cordova.activity

            // set service-side lambda that will be invoked by RecordingService
            RecordingService.previewFrameCallback = fun(base64Frame: String) {
                try {
                    val currentAct = act
                    if (currentAct == null || currentAct.isFinishing ||
                        (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.JELLY_BEAN_MR1 && currentAct.isDestroyed)
                    ) {
                        android.util.Log.w("VideoRecorder", "preview lambda: activity gone, clearing callback")
                        RecordingService.previewFrameCallback = null
                        previewCallback = null
                        return
                    }

                    android.util.Log.v("VideoRecorder", "preview lambda: forwarding frame to JS (len=${base64Frame.length})")
                    val frameResult = org.apache.cordova.PluginResult(org.apache.cordova.PluginResult.Status.OK, base64Frame)
                    frameResult.keepCallback = true
                    previewCallback?.sendPluginResult(frameResult)
                } catch (ex: Exception) {
                    android.util.Log.w("VideoRecorder", "preview lambda: sendPluginResult failed: ${ex.message}")
                    RecordingService.previewFrameCallback = null
                    previewCallback = null

                    try {
                        val currentAct = act
                        if (currentAct != null) {
                            val stopIntent = android.content.Intent(currentAct, RecordingService::class.java).apply { action = "STOP_PREVIEW" }
                            currentAct.runOnUiThread {
                                try {
                                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) currentAct.startForegroundService(stopIntent)
                                    else currentAct.startService(stopIntent)
                                } catch (_: Exception) { /* ignore */ }
                            }
                        }
                    } catch (_: Exception) { /* ignore */ }
                }
            }

            // now tell the service to start previewing
            val intent = android.content.Intent(activity, RecordingService::class.java).apply { action = "START_PREVIEW" }
            activity.runOnUiThread {
                try {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) activity.startForegroundService(intent)
                    else activity.startService(intent)
                } catch (e: Exception) {
                    RecordingService.previewFrameCallback = null
                    previewCallback = null
                    try { callbackContext.error("Failed to start preview service: ${e.message}") } catch (_: Exception) {}
                }
            }
        } else {
            // stop preview: clear service callback, notify JS once, and send STOP_PREVIEW intent
            RecordingService.previewFrameCallback = null

            val stopResult = org.apache.cordova.PluginResult(org.apache.cordova.PluginResult.Status.OK, "preview_stopped")
            stopResult.keepCallback = false
            try {
                callbackContext.sendPluginResult(stopResult)
            } catch (e: Exception) {
                // ignore send errors
            }

            previewCallback = null

            val intent = android.content.Intent(activity, RecordingService::class.java).apply { action = "STOP_PREVIEW" }
            activity.runOnUiThread {
                try {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) activity.startForegroundService(intent)
                    else activity.startService(intent)
                } catch (_: Exception) { /* ignore */ }
            }
        }
    }

    /**
     * Start preview using an options object (same shape as start):
     * { camera: "front"|"back", resolution: "1080x1920", fps: 10 }
     *
     * This is a separate function name to avoid signature collision with the boolean overload.
     */
    private fun handlePreviewWithOptions(options: JSONObject, callbackContext: CallbackContext) {
        val activity = cordova.activity ?: run {
            callbackContext.error("No activity")
            return
        }

        // Register the Cordova callback first (same behavior as boolean path)
        previewCallback = callbackContext

        val startResult = PluginResult(PluginResult.Status.OK, "preview_started")
        startResult.keepCallback = true
        try {
            android.util.Log.d("VideoRecorder", "handlePreviewWithOptions: sending preview_started and keeping callback")
            previewCallback?.sendPluginResult(startResult)
        } catch (e: Exception) {
            previewCallback = null
            callbackContext.error("Failed to register preview callback: ${e.message}")
            return
        }

        // capture activity reference for use inside the lambda
        val act = cordova.activity

        // set service-side lambda that will be invoked by RecordingService (same as boolean path)
        RecordingService.previewFrameCallback = fun(base64Frame: String) {
            try {
                val currentAct = act
                if (currentAct == null || currentAct.isFinishing ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && currentAct.isDestroyed)
                ) {
                    android.util.Log.w("VideoRecorder", "preview lambda: activity gone, clearing callback")
                    RecordingService.previewFrameCallback = null
                    previewCallback = null
                    return
                }

                android.util.Log.v("VideoRecorder", "preview lambda: forwarding frame to JS (len=${base64Frame.length})")
                val frameResult = PluginResult(PluginResult.Status.OK, base64Frame)
                frameResult.keepCallback = true
                previewCallback?.sendPluginResult(frameResult)
            } catch (ex: Exception) {
                android.util.Log.w("VideoRecorder", "preview lambda: sendPluginResult failed: ${ex.message}")
                RecordingService.previewFrameCallback = null
                previewCallback = null

                try {
                    val currentAct = act
                    if (currentAct != null) {
                        val stopIntent = Intent(currentAct, RecordingService::class.java).apply { action = "STOP_PREVIEW" }
                        currentAct.runOnUiThread {
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) currentAct.startForegroundService(stopIntent)
                                else currentAct.startService(stopIntent)
                            } catch (_: Exception) { /* ignore */ }
                        }
                    }
                } catch (_: Exception) { /* ignore */ }
            }
        }

        // Parse options and forward them as extras to the service
        val camera = options.optString("camera", "back")
        val resolution = options.optString("resolution", "")
        val fps = options.optInt("fps", 0)

        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "START_PREVIEW"
            putExtra("camera", camera)
            if (resolution.isNotEmpty()) putExtra("resolution", resolution)
            if (fps > 0) putExtra("fps", fps)
        }

        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) activity.startForegroundService(intent)
                else activity.startService(intent)
            } catch (e: Exception) {
                RecordingService.previewFrameCallback = null
                previewCallback = null
                try { callbackContext.error("Failed to start preview service: ${e.message}") } catch (_: Exception) {}
            }
        }
    }


    private fun requestStopPreviewFromPlugin() {
        val act = cordova.activity ?: return
        try {
            val stopIntent = android.content.Intent(act, RecordingService::class.java).apply { action = "STOP_PREVIEW" }
            act.runOnUiThread {
                try {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) act.startForegroundService(stopIntent)
                    else act.startService(stopIntent)
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
    }

}
