package io.globules.videorecorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.camera2.*
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import com.arthenica.ffmpegkit.FFmpegKit
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.*

class RecordingService : Service() {

    companion object {
        var stopWithCallback: ((String?) -> Unit)? = null
        private const val CHANNEL_ID = "video_recorder_channel"
    }

    private lateinit var cameraManager: CameraManager
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var mediaRecorder: MediaRecorder? = null
    private var outputFile: String? = null

    private var videoWidth = 1920
    private var videoHeight = 1080
    private var videoBitrate = 10_000_000
    private var maxLengthSec = 0
    private var isRecording = false
    private var cameraFacing: Int = CameraCharacteristics.LENS_FACING_BACK
    private var saveToGallery: Boolean = false

    // ⭐ WATERMARK OPTIONS
    private var watermarkEnabled = false
    private var watermarkImage: String? = null
    private var watermarkPosition: String = "bottomright"

    override fun onCreate() {
        super.onCreate()
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        createNotificationChannel()

        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                1,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            )
        } else {
            startForeground(1, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {

        if (intent?.action == "STOP_RECORDING") {
            stopRecording()
            return START_NOT_STICKY
        }

        if (!isRecording) {

            val resolution = intent?.getStringExtra("resolution") ?: "1920x1080"
            val bitrate = intent?.getIntExtra("bitrate", 10_000_000) ?: 10_000_000
            val maxLength = intent?.getIntExtra("maxLength", 0) ?: 0
            val camera = intent?.getStringExtra("camera") ?: "back"
            saveToGallery = intent?.getBooleanExtra("saveToGallery", false) ?: false

            // ⭐ WATERMARK EXTRAS
            watermarkEnabled = intent?.getBooleanExtra("watermarkEnabled", false) ?: false
            watermarkImage = intent?.getStringExtra("watermarkImage")
            watermarkPosition = intent?.getStringExtra("watermarkPosition") ?: "bottomright"

            parseResolution(resolution)
            videoBitrate = bitrate
            maxLengthSec = maxLength
            cameraFacing =
                if (camera.lowercase(Locale.US) == "front") {
                    CameraCharacteristics.LENS_FACING_FRONT
                } else {
                    CameraCharacteristics.LENS_FACING_BACK
                }

            startCameraRecording()
        }

        return START_STICKY
    }

    // ⭐ Resolve PNG from assets/www
    private fun resolveWatermarkAsset(relativePath: String): File? {
        return try {
            val assetPath = "www/$relativePath"
            val input = assets.open(assetPath)

            val temp = File(cacheDir, "wm_${System.currentTimeMillis()}.png")
            input.copyTo(temp.outputStream())
            temp
        } catch (e: Exception) {
            null
        }
    }

    // ⭐ Position mapping identical to iOS
    private fun ffmpegOverlayPosition(pos: String): String {
        return when (pos.lowercase()) {
            "topleft" -> "10:10"
            "topright" -> "main_w-overlay_w-10:10"
            "bottomleft" -> "10:main_h-overlay_h-10"
            else -> "main_w-overlay_w-10:main_h-overlay_h-10" // bottomright
        }
    }

    // ⭐ FFmpeg watermark export
    private fun exportWithWatermark(input: File, watermark: File, position: String, callback: (File?) -> Unit) {

        val output = File(
            cacheDir,
            "VID_WM_${System.currentTimeMillis()}.mp4"
        )

        val overlayPos = ffmpegOverlayPosition(position)

        val cmd = arrayOf(
			"-i", input.absolutePath,
			"-i", watermark.absolutePath,
			"-filter_complex", "overlay=$overlayPos",
			"-c:v", "libx264",
			"-preset", "ultrafast",
			"-crf", "18",
			"-c:a", "copy",
			output.absolutePath
		)

        FFmpegKit.executeAsync(cmd.joinToString(" ")) { session ->
            val returnCode = session.returnCode

            if (returnCode.isValueSuccess) {
                callback(output)
            } else {
                callback(null)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Recording video")
            .setContentText("Video recording in progress")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val chan =
                NotificationChannel(
                    CHANNEL_ID,
                    "Video Recorder",
                    NotificationManager.IMPORTANCE_LOW
                )
            val mgr = getSystemService(NotificationManager::class.java)
            mgr.createNotificationChannel(chan)
        }
    }

    private fun parseResolution(resolution: String) {
        val parts = resolution.lowercase(Locale.US).split("x")
        if (parts.size == 2) {
            val w = parts[0].toIntOrNull()
            val h = parts[1].toIntOrNull()
            if (w != null && h != null && w > 0 && h > 0) {
                videoWidth = w
                videoHeight = h
            }
        }
    }

    private fun startCameraRecording() {
        try {
            val cameraId =
                findCameraIdForFacing(cameraFacing)
                    ?: cameraManager.cameraIdList.firstOrNull() ?: return

            cameraManager.openCamera(
                cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        cameraDevice = device
                        setupMediaRecorder()
                        createCaptureSession()
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        device.close()
                        stopSelf()
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        device.close()
                        stopSelf()
                    }
                },
                null
            )
        } catch (e: SecurityException) {
            stopSelf()
        }
    }

    private fun findCameraIdForFacing(facing: Int): String? {
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val lensFacing = chars.get(CameraCharacteristics.LENS_FACING)
            if (lensFacing == facing) return id
        }
        return null
    }

    private fun setupMediaRecorder() {
        val dir = getExternalFilesDir(Environment.DIRECTORY_MOVIES)
        if (dir != null && !dir.exists()) dir.mkdirs()

        val ts = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val file = File(dir, "VID_$ts.mp4")
        outputFile = file.absolutePath

        mediaRecorder =
            MediaRecorder().apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setOutputFile(outputFile)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setVideoEncodingBitRate(videoBitrate)
                setVideoFrameRate(30)
                setVideoSize(videoWidth, videoHeight)

                if (maxLengthSec > 0) {
                    setMaxDuration(maxLengthSec * 1000)
                }

                setOnInfoListener { _, what, _ ->
                    if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) {
                        stopRecording()
                    }
                }

                prepare()
            }
    }

    private fun createCaptureSession() {
        val surface = mediaRecorder!!.surface
        cameraDevice?.createCaptureSession(
            listOf(surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    val requestBuilder =
                        cameraDevice!!.createCaptureRequest(
                            CameraDevice.TEMPLATE_RECORD
                        )
                    requestBuilder.addTarget(surface)
                    requestBuilder.set(
                        CaptureRequest.CONTROL_MODE,
                        CameraMetadata.CONTROL_MODE_AUTO
                    )
                    session.setRepeatingRequest(requestBuilder.build(), null, null)
                    mediaRecorder?.start()
                    isRecording = true
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    stopSelf()
                }
            },
            null
        )
    }

    private fun stopRecording() {
        if (!isRecording) {
            stopWithCallback?.invoke(null)
            stopWithCallback = null
            stopForeground(true)
            stopSelf()
            return
        }

        isRecording = false

        try {
            mediaRecorder?.apply {
                try { stop() } catch (_: Exception) {}
                reset()
                release()
            }
        } catch (_: Exception) {}

        mediaRecorder = null

        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null

        try { cameraDevice?.close() } catch (_: Exception) {}
        cameraDevice = null

        val originalPath = outputFile
        outputFile = null

        if (originalPath == null) {
            stopWithCallback?.invoke(null)
            stopWithCallback = null
            stopForeground(true)
            stopSelf()
            return
        }

        val originalFile = File(originalPath)
       
        exportWithWatermark(originalFile, wmFile, watermarkPosition) { watermarked ->

               if (watermarked != null) {
                    if (saveToGallery) {
                         val finalUri = moveToGallery(watermarked.absolutePath)
                         stopWithCallback?.invoke(finalUri)  
                    } else {
                         stopWithCallback?.invoke("file://${watermarked.absolutePath}")
                    }
               } else {
                    // fallback
                    if (saveToGallery) {
                         val finalUri = moveToGallery(originalPath)
                         stopWithCallback?.invoke(finalUri)  
                    } else {
                         stopWithCallback?.invoke("file://$originalPath")
                    }
               }

               stopWithCallback = null
               stopForeground(true)
               stopSelf()
          }


        val finalFile = originalFile

        if (saveToGallery) {
            moveToGallery(finalFile.absolutePath)
        }

        // ALWAYS return a real file path
        stopWithCallback?.invoke(finalFile.absolutePath)

        stopWithCallback = null
        stopForeground(true)
        stopSelf()
    }


    private fun moveToGallery(path: String): String? {
        val file = File(path)
        if (!file.exists()) return null

        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "DCIM/Camera/")
        }

        val uri: Uri? =
            resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)

        if (uri != null) {
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(file).use { input ->
                    input.copyTo(out)
                }
            }

            file.delete()

            return uri.toString()
        }

        return null
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isRecording) {
            stopRecording()
        }
    }
}
