package io.globules.videorecorder

import android.content.Intent
import android.os.Build
import org.apache.cordova.CallbackContext
import org.apache.cordova.CordovaPlugin
import org.json.JSONArray
import org.json.JSONObject

class VideoRecorder : CordovaPlugin() {

    private var currentCallback: CallbackContext? = null

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

        // ⭐ WATERMARK OPTIONS
        var watermarkEnabled = false
        var watermarkImage: String? = null
        var watermarkPosition = "bottomright"

        val wm: Any? = options.opt("watermark")
        if (wm is JSONObject) {
            watermarkEnabled = true
            watermarkImage = if (wm.has("image")) wm.getString("image") else null
            watermarkPosition = wm.optString("position", "bottomright")
        }

        // ⭐ CALLBACK FROM RecordingService
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

			currentCallback?.success(safePath as String)
			currentCallback = null
		}


        // ⭐ START SERVICE WITH ALL OPTIONS
        val intent = Intent(activity, RecordingService::class.java).apply {
            action = "START_RECORDING"
            putExtra("resolution", resolution)
            putExtra("bitrate", bitrate)
            putExtra("maxLength", maxLength)
            putExtra("camera", camera)
            putExtra("saveToGallery", saveToGallery)

            // ⭐ WATERMARK EXTRAS
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
}
