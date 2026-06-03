package io.globules.VideoRecorder

import android.content.Intent
import org.apache.cordova.CallbackContext
import org.apache.cordova.CordovaPlugin
import org.json.JSONArray
import org.json.JSONObject

class VideoRecorder : CordovaPlugin() {

     private var callbackContext: CallbackContext? = null

     override fun execute(
             action: String,
             args: JSONArray,
             callbackContext: CallbackContext
     ): Boolean {
          return when (action) {
               "start" -> {
                    this.callbackContext = callbackContext
                    val options =
                            if (args.length() > 0) args.optJSONObject(0) ?: JSONObject()
                            else JSONObject()
                    startRecording(options)
                    true
               }
               "stop" -> {
                    this.callbackContext = callbackContext
                    stopRecording()
                    true
               }
               else -> false
          }
     }

     private fun startRecording(options: JSONObject) {
          val activity = cordova.activity ?: return

          val maxLength = options.optInt("maxLength", 0) // seconds, 0 = unlimited
          val resolution = options.optString("resolution", "1920x1080")
          val bitrate = options.optInt("bitrate", 10_000_000) // bits per second
          val camera = options.optString("camera", "back") // "front" | "back"

          val intent = Intent(activity, RecordingService::class.java)
          intent.putExtra("maxLength", maxLength)
          intent.putExtra("resolution", resolution)
          intent.putExtra("bitrate", bitrate)
          intent.putExtra("camera", camera)

          activity.startForegroundService(intent)
          callbackContext?.success()
     }

     private fun stopRecording() {
          val activity = cordova.activity ?: return

          RecordingService.stopWithCallback = { filePath ->
               val safePath = filePath ?: ""

               val js =
                       """
            document.dispatchEvent(new CustomEvent('VideoRecorderFinished', {
                detail: { file: '$safePath' }
            }));
        """.trimIndent()

               webView?.engine?.loadUrl("javascript:$js")

               callbackContext?.success()
          }

          val intent = Intent(activity, RecordingService::class.java)
          intent.action = "STOP_RECORDING"
          activity.startService(intent)
     }
}
