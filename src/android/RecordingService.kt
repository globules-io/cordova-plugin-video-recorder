package io.globules.videorecorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.*
import android.media.Image
import android.media.ImageReader
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import com.arthenica.ffmpegkit.FFmpegKit
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.*

class RecordingService : Service() {

    companion object {
        var stopWithCallback: ((String?) -> Unit)? = null
        private const val CHANNEL_ID = "video_recorder_channel"

        // New: preview frame callback (base64 JPEG string)
        @Volatile
        var previewFrameCallback: ((String) -> Unit)? = null
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

    // WATERMARK OPTIONS
    private var watermarkEnabled = false
    private var watermarkImage: String? = null
    private var watermarkPosition: String = "bottomright"

    // --- Preview related fields ---
    private var previewEnabled = false
    private var previewReader: ImageReader? = null
    private var previewHandlerThread: HandlerThread? = null
    private var previewHandler: Handler? = null
    private var lastPreviewSentAt = 0L
    private var previewTargetFps = 10 // tuneable: target preview FPS
    private var previewJpegQuality = 60 // tuneable: JPEG quality for preview

    override fun onCreate() {
        super.onCreate()
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        createNotificationChannel()
        val notification = buildNotification()

        // Defensive foreground start: only request camera-type foreground if we have CAMERA permission.
        val hasCameraPermission = androidx.core.content.ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.CAMERA
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && hasCameraPermission) {
            try {
                startForeground(
                    1,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                )
            } catch (se: SecurityException) {
                android.util.Log.w("RecordingService", "startForeground with camera type denied, falling back: ${se.message}")
                startForeground(1, notification)
            }
        } else {
            startForeground(1, notification)
        }

        // Debug: log PID so you can confirm service runs in same process as plugin
        android.util.Log.d("RecordingService", "onCreate: pid=${android.os.Process.myPid()} package=${applicationContext.packageName}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val TAG = "RecordingService"
        try {
            if (intent == null) {
                android.util.Log.w(TAG, "onStartCommand: null intent")
                return Service.START_STICKY
            }

            val action = intent.action
            android.util.Log.d(TAG, "onStartCommand: action=$action")

            when (action) {
                "START_RECORDING" -> {
                    // Read extras (defensive parsing)
                    try {
                        val resolution = intent.getStringExtra("resolution") ?: "${videoWidth}x${videoHeight}"
                        val bitrate = intent.getIntExtra("bitrate", videoBitrate)
                        val maxLength = intent.getIntExtra("maxLength", maxLengthSec)
                        val camera = intent.getStringExtra("camera") ?: if (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT) "front" else "back"
                        saveToGallery = intent.getBooleanExtra("saveToGallery", saveToGallery)

                        // WATERMARK EXTRAS
                        watermarkEnabled = intent.getBooleanExtra("watermarkEnabled", watermarkEnabled)
                        watermarkImage = intent.getStringExtra("watermarkImage") ?: watermarkImage
                        watermarkPosition = intent.getStringExtra("watermarkPosition") ?: watermarkPosition

                        // Apply parsed options
                        parseResolution(resolution)
                        videoBitrate = bitrate
                        maxLengthSec = maxLength
                        cameraFacing = if (camera.lowercase(java.util.Locale.US) == "front") {
                            CameraCharacteristics.LENS_FACING_FRONT
                        } else {
                            CameraCharacteristics.LENS_FACING_BACK
                        }

                        // Start camera recording pipeline (method exists in this class)
                        startCameraRecording()
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "START_RECORDING failed: ${e.message}")
                    }
                    // Keep service alive while recording
                    return Service.START_STICKY
                }

                "STOP_RECORDING" -> {
                    try {
                        stopRecording()
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "STOP_RECORDING failed: ${e.message}")
                    }
                    return Service.START_NOT_STICKY
                }

                "START_PREVIEW" -> {
                    try {
                        // If preview requires camera permission, caller should ensure it is granted.
                        // Start preview pipeline (safe, idempotent)
                        startPreviewMode()
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "START_PREVIEW failed: ${e.message}")
                    }
                    // Keep service alive while previewing
                    return Service.START_STICKY
                }

                "STOP_PREVIEW" -> {
                    try {
                        stopPreviewMode()
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "STOP_PREVIEW failed: ${e.message}")
                    }
                    return Service.START_NOT_STICKY
                }

                else -> {
                    android.util.Log.w(TAG, "Unknown action in onStartCommand: $action")
                    return Service.START_NOT_STICKY
                }
            }
        } catch (e: Throwable) {
            // Catch-all to avoid crashing the service process on unexpected errors
            android.util.Log.e("RecordingService", "onStartCommand fatal error: ${e.message}", e)
            try {
                // Best-effort cleanup
                stopPreviewMode()
                stopRecording()
            } catch (_: Exception) {}
            return Service.START_NOT_STICKY
        }
    }

    // Resolve watermark asset (unchanged)
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

    private fun ffmpegOverlayPosition(pos: String): String {
        return when (pos.lowercase()) {
            "topleft" -> "10:10"
            "topright" -> "main_w-overlay_w-10:10"
            "bottomleft" -> "10:main_h-overlay_h-10"
            else -> "main_w-overlay_w-10:main_h-overlay_h-10"
        }
    }

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

    /**
     * Choose the best supported MediaRecorder size for the given cameraId.
     * Preference order:
     * 1) exact match (videoWidth x videoHeight)
     * 2) rotated match (videoHeight x videoWidth)
     * 3) closest by absolute area difference
     *
     * Returns Pair(width, height) or null if no sizes available.
     */
    private fun chooseBestVideoSizeForCamera(cameraId: String?): Pair<Int, Int>? {
        try {
            val id = cameraId ?: findCameraIdForFacing(cameraFacing) ?: return null
            val chars = cameraManager.getCameraCharacteristics(id)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return null
            val sizes = map.getOutputSizes(MediaRecorder::class.java) ?: return null

            // Convert to list of pairs
            val supported = sizes.map { Pair(it.width, it.height) }

            // 1) exact match
            supported.firstOrNull { it.first == videoWidth && it.second == videoHeight }?.let { return it }

            // 2) rotated match (swap)
            supported.firstOrNull { it.first == videoHeight && it.second == videoWidth }?.let {
                android.util.Log.d("RecordingService", "chooseBestVideoSize: using rotated match ${it.first}x${it.second} for requested ${videoWidth}x${videoHeight}")
                return it
            }

            // 3) choose closest by area difference (prefer same orientation if possible)
            val requestedArea = videoWidth.toLong() * videoHeight.toLong()
            var best: Pair<Int, Int>? = null
            var bestDiff = Long.MAX_VALUE

            for (s in supported) {
                val area = s.first.toLong() * s.second.toLong()
                val diff = kotlin.math.abs(area - requestedArea)
                if (diff < bestDiff) {
                    bestDiff = diff
                    best = s
                }
            }

            if (best != null) {
                android.util.Log.d("RecordingService", "chooseBestVideoSize: selected closest supported ${best.first}x${best.second} for requested ${videoWidth}x${videoHeight}")
            } else {
                android.util.Log.w("RecordingService", "chooseBestVideoSize: no supported sizes found")
            }
            return best
        } catch (e: Exception) {
            android.util.Log.w("RecordingService", "chooseBestVideoSizeForCamera error: ${e.message}")
            return null
        }
    }
     

    /**
     * Setup MediaRecorder but first pick a compatible recorder size from the camera's supported sizes.
     * This replaces the previous setupMediaRecorder() to avoid onConfigureFailed due to unsupported sizes.
     */
    private fun setupMediaRecorder() {
        // Ensure output dir exists
        val dir = getExternalFilesDir(Environment.DIRECTORY_MOVIES)
        if (dir != null && !dir.exists()) dir.mkdirs()

        // Pick best supported size for the camera
        val cameraId = try { findCameraIdForFacing(cameraFacing) } catch (_: Exception) { null }
        val chosen = chooseBestVideoSizeForCamera(cameraId)

        if (chosen != null) {
            val (chosenW, chosenH) = chosen
            // Update videoWidth/videoHeight to the chosen supported size
            if (chosenW != videoWidth || chosenH != videoHeight) {
                android.util.Log.d("RecordingService", "setupMediaRecorder: adjusting requested size ${videoWidth}x${videoHeight} -> supported ${chosenW}x${chosenH}")
                videoWidth = chosenW
                videoHeight = chosenH
            } else {
                android.util.Log.d("RecordingService", "setupMediaRecorder: using requested size ${videoWidth}x${videoHeight}")
            }
        } else {
            android.util.Log.w("RecordingService", "setupMediaRecorder: could not determine supported recorder size; proceeding with requested ${videoWidth}x${videoHeight}")
        }

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

                // Try to set orientation hint so the file plays upright
                try {
                    val camId = findCameraIdForFacing(cameraFacing)
                    val chars = camId?.let { cameraManager.getCameraCharacteristics(it) }
                    val sensorOrientation = chars?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0

                    val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
                    val rotation = wm.defaultDisplay.rotation
                    val degrees = when (rotation) {
                        android.view.Surface.ROTATION_0 -> 0
                        android.view.Surface.ROTATION_90 -> 90
                        android.view.Surface.ROTATION_180 -> 180
                        android.view.Surface.ROTATION_270 -> 270
                        else -> 0
                    }

                    val orientationHint = if (chars?.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT) {
                        (sensorOrientation + degrees) % 360
                    } else {
                        (sensorOrientation - degrees + 360) % 360
                    }

                    android.util.Log.d("RecordingService", "setupMediaRecorder: sensorOrientation=$sensorOrientation deviceRotation=$degrees orientationHint=$orientationHint")
                    setOrientationHint(orientationHint)
                } catch (e: Exception) {
                    android.util.Log.w("RecordingService", "setupMediaRecorder: failed to set orientation hint: ${e.message}")
                }

                try {
                    prepare()
                } catch (e: Exception) {
                    android.util.Log.w("RecordingService", "setupMediaRecorder prepare() failed: ${e.message}")
                    // If prepare fails, try to fallback by selecting a different supported size (one more attempt)
                    try {
                        val fallback = chooseBestVideoSizeForCamera(cameraId)
                        if (fallback != null && (fallback.first != videoWidth || fallback.second != videoHeight)) {
                            videoWidth = fallback.first
                            videoHeight = fallback.second
                            android.util.Log.d("RecordingService", "setupMediaRecorder: retrying prepare with fallback size ${videoWidth}x${videoHeight}")
                            setVideoSize(videoWidth, videoHeight)
                            prepare()
                        } else {
                            throw e
                        }
                    } catch (ex: Exception) {
                        android.util.Log.e("RecordingService", "setupMediaRecorder: prepare retry failed: ${ex.message}")
                        throw ex
                    }
                }
            }
    }


    private fun createCaptureSession() {
        val TAG = "RecordingService"
        val surface = mediaRecorder!!.surface

        // Log camera id and requested sizes
        val camId = try { findCameraIdForFacing(cameraFacing) } catch (_: Exception) { null }
        android.util.Log.d(TAG, "createCaptureSession: cameraId=$camId videoSize=${videoWidth}x${videoHeight} previewEnabled=$previewEnabled")

        // Choose a smaller preview size for performance (only used when previewEnabled)
        val previewW = (videoWidth / 3).coerceAtLeast(320)
        val previewH = (videoHeight / 3).coerceAtLeast(180)

        // If preview is enabled, ensure preview handler and reader exist and listener installed
        if (previewEnabled) {
            if (previewHandlerThread == null) {
                previewHandlerThread = HandlerThread("PreviewThread").apply { start() }
                previewHandler = Handler(previewHandlerThread!!.looper)
            }
            if (previewReader == null) {
                previewReader = ImageReader.newInstance(previewW, previewH, ImageFormat.YUV_420_888, 2)
                setPreviewImageAvailableListener(previewReader!!, previewW, previewH)
            }
        }

        // Build target surfaces list: always include recorder surface; include preview surface only when enabled
        val targets = mutableListOf(surface)
        if (previewEnabled) {
            previewReader?.surface?.let { targets.add(it) }
        }

        // Log the targets we will request (use known sizes instead of reading Surface properties)
        try {
            val targetNames = targets.map { t ->
                when {
                    t === surface -> "RecorderSurface(${videoWidth}x${videoHeight})"
                    previewReader != null && t === previewReader!!.surface -> "PreviewSurface(${previewW}x${previewH})"
                    else -> "Surface(${t.toString()})"
                }
            }.joinToString(", ")
            android.util.Log.d(TAG, "createCaptureSession: targets = $targetNames")
        } catch (_: Exception) {
            android.util.Log.w(TAG, "createCaptureSession: failed to build target names for logging")
        }


        // Log supported output sizes for debugging (best-effort)
        try {
            val id = camId ?: cameraManager.cameraIdList.firstOrNull()
            if (id != null) {
                val chars = cameraManager.getCameraCharacteristics(id)
                val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                if (map != null) {
                    val sizesRec = map.getOutputSizes(MediaRecorder::class.java) ?: emptyArray()
                    val sizesImg = map.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray()
                    android.util.Log.d(TAG, "createCaptureSession: supported MediaRecorder sizes: ${sizesRec.joinToString { "${it.width}x${it.height}" }}")
                    android.util.Log.d(TAG, "createCaptureSession: supported ImageReader (YUV) sizes: ${sizesImg.joinToString { "${it.width}x${it.height}" }}")
                }
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "createCaptureSession: failed to query supported sizes: ${e.message}")
        }

        // Helper to actually create the session given a list of targets and a handler
        fun doCreateSession(targetSurfaces: List<android.view.Surface>, handler: Handler?) {
            try {
                cameraDevice?.createCaptureSession(
                    targetSurfaces,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            captureSession = session
                            try {
                                val requestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                requestBuilder.addTarget(surface)
                                if (previewEnabled && previewReader != null && targetSurfaces.contains(previewReader!!.surface)) {
                                    previewReader?.surface?.let { requestBuilder.addTarget(it) }
                                }
                                requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                session.setRepeatingRequest(requestBuilder.build(), null, handler)
                                mediaRecorder?.start()
                                isRecording = true
                                android.util.Log.d(TAG, "createCaptureSession: onConfigured - recording started")
                            } catch (e: Exception) {
                                android.util.Log.w(TAG, "createCaptureSession: onConfigured failed to start recording: ${e.message}")
                                stopSelf()
                            }
                        }

                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            android.util.Log.w(TAG, "createCaptureSession: onConfigureFailed for targets=${targetSurfaces.size}")
                            // If we failed while including preview, try a fallback with only recorder surface
                            if (previewEnabled && targetSurfaces.any { it == previewReader?.surface }) {
                                android.util.Log.d(TAG, "createCaptureSession: retrying without preview surface (fallback)")
                                try {
                                    // Close previous session if any
                                    try { captureSession?.close() } catch (_: Exception) {}
                                    captureSession = null
                                    // Retry with only recorder surface
                                    doCreateSession(listOf(surface), null)
                                } catch (e: Exception) {
                                    android.util.Log.w(TAG, "createCaptureSession: fallback retry failed: ${e.message}")
                                    stopSelf()
                                }
                            } else {
                                stopSelf()
                            }
                        }
                    },
                    handler
                )
            } catch (e: Exception) {
                android.util.Log.w(TAG, "createCaptureSession: createCaptureSession threw: ${e.message}")
                // If we attempted with preview, try fallback
                if (previewEnabled) {
                    android.util.Log.d(TAG, "createCaptureSession: createCaptureSession threw, retrying without preview")
                    try {
                        doCreateSession(listOf(surface), null)
                    } catch (ex: Exception) {
                        android.util.Log.w(TAG, "createCaptureSession: fallback createCaptureSession threw: ${ex.message}")
                        stopSelf()
                    }
                } else {
                    stopSelf()
                }
            }
        }

        // Kick off session creation with the chosen targets
        doCreateSession(targets, previewHandler)
    }

    // Convert YUV_420_888 Image to JPEG bytes (NV21 -> YuvImage -> compressToJpeg)
    private fun yuvToJpegBytes(image: Image, width: Int, height: Int, quality: Int): ByteArray {
        val yBuffer = image.planes[0].buffer
        val uBuffer = image.planes[1].buffer
        val vBuffer = image.planes[2].buffer

        val ySize = yBuffer.remaining()
        val uSize = uBuffer.remaining()
        val vSize = vBuffer.remaining()

        val nv21 = ByteArray(ySize + uSize + vSize)
        yBuffer.get(nv21, 0, ySize)

        val uBytes = ByteArray(uSize)
        val vBytes = ByteArray(vSize)
        uBuffer.get(uBytes)
        vBuffer.get(vBytes)

        // Interleave V and U to NV21
        var i = 0
        val chromaStart = ySize
        while (i < uSize && chromaStart + 2 * i + 1 < nv21.size) {
            nv21[chromaStart + 2 * i] = vBytes[i]
            nv21[chromaStart + 2 * i + 1] = uBytes[i]
            i++
        }

        val out = ByteArrayOutputStream()
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)
        return out.toByteArray()
    } 
   
    private fun setPreviewImageAvailableListener(reader: ImageReader, previewW: Int, previewH: Int) {
        try { reader.setOnImageAvailableListener(null, null) } catch (_: Exception) {}

        reader.setOnImageAvailableListener({ r ->
            // Acquire latest image and copy its data immediately on the camera thread
            val image = try { r.acquireLatestImage() } catch (e: Exception) {
                android.util.Log.w("RecordingService", "acquireLatestImage threw: ${e?.message}")
                null
            } ?: return@setOnImageAvailableListener

            // Defensive: read and copy buffers now, before closing the Image
            val nv21Copy: ByteArray? = try {
                val yPlane = image.planes[0]
                val uPlane = image.planes[1]
                val vPlane = image.planes[2]

                val yBuffer = yPlane.buffer
                val uBuffer = uPlane.buffer
                val vBuffer = vPlane.buffer

                val ySize = yBuffer.remaining()
                val uSize = uBuffer.remaining()
                val vSize = vBuffer.remaining()

                val nv21 = ByteArray(ySize + uSize + vSize)
                yBuffer.get(nv21, 0, ySize)

                val uBytes = ByteArray(uSize)
                val vBytes = ByteArray(vSize)
                uBuffer.get(uBytes)
                vBuffer.get(vBytes)

                // Interleave V and U to NV21
                var i = 0
                val chromaStart = ySize
                while (i < uSize && chromaStart + 2 * i + 1 < nv21.size) {
                    nv21[chromaStart + 2 * i] = vBytes[i]
                    nv21[chromaStart + 2 * i + 1] = uBytes[i]
                    i++
                }
                nv21
            } catch (e: Exception) {
                android.util.Log.w("RecordingService", "copying image planes failed: ${e.message}")
                null
            } finally {
                // Always close the Image on the camera thread immediately
                try { image.close() } catch (e: Exception) { android.util.Log.w("RecordingService", "image.close() failed: ${e.message}") }
            }

            if (nv21Copy == null) return@setOnImageAvailableListener

            // Early guard on camera thread: if preview disabled or no callback, stop early to avoid posting work
            if (!previewEnabled || previewFrameCallback == null) {
                android.util.Log.d("RecordingService", "early-exit: previewEnabled=$previewEnabled callbackSet=${previewFrameCallback != null}")
                // If callback is missing but previewEnabled is true, request STOP_PREVIEW to clean up
                if (previewEnabled && previewFrameCallback == null) {
                    previewEnabled = false
                    try {
                        val stopIntent = Intent(this@RecordingService, RecordingService::class.java).apply { action = "STOP_PREVIEW" }
                        Handler(Looper.getMainLooper()).post {
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(stopIntent) else startService(stopIntent)
                            } catch (_: Exception) {}
                        }
                    } catch (_: Exception) {}
                }
                return@setOnImageAvailableListener
            }

            // Throttle by timestamp on camera thread before posting
            val now = System.currentTimeMillis()
            val minIntervalMs = if (previewTargetFps > 0) (1000L / previewTargetFps) else 0L
            if (minIntervalMs > 0 && now - lastPreviewSentAt < minIntervalMs) {
                return@setOnImageAvailableListener
            }
            lastPreviewSentAt = now

            // Offload JPEG compression to previewHandler using the copied NV21 bytes
            previewHandler?.post {
                try {
                    // Double-check on handler thread before heavy work
                    if (!previewEnabled || previewFrameCallback == null) {
                        android.util.Log.d("RecordingService", "handler-guard: previewEnabled=$previewEnabled callbackSet=${previewFrameCallback != null}")
                        if (previewEnabled && previewFrameCallback == null) {
                            previewEnabled = false
                            try {
                                val stopIntent = Intent(this@RecordingService, RecordingService::class.java).apply { action = "STOP_PREVIEW" }
                                Handler(Looper.getMainLooper()).post {
                                    try {
                                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(stopIntent) else startService(stopIntent)
                                    } catch (_: Exception) {}
                                }
                            } catch (_: Exception) {}
                        }
                        return@post
                    }

                    // Convert NV21 byte[] to JPEG using YuvImage
                    val out = ByteArrayOutputStream()
                    try {
                        val yuvImage = YuvImage(nv21Copy, ImageFormat.NV21, previewW, previewH, null)
                        yuvImage.compressToJpeg(Rect(0, 0, previewW, previewH), previewJpegQuality, out)
                    } catch (e: Exception) {
                        android.util.Log.w("RecordingService", "YuvImage.compressToJpeg failed: ${e.message}")
                        return@post
                    }

                    val jpeg = out.toByteArray()
                    val b64 = try { android.util.Base64.encodeToString(jpeg, android.util.Base64.NO_WRAP) } catch (e: Exception) {
                        android.util.Log.w("RecordingService", "Base64 encode failed: ${e.message}")
                        return@post
                    }

                    val dataUri = "data:image/jpeg;base64,$b64"

                    // Log state before invoking callback
                    try {
                        val pid = android.os.Process.myPid()
                        val tid = android.os.Process.myTid()
                        val cbSet = previewFrameCallback != null
                        android.util.Log.d("RecordingService", "preview-beforeInvoke: pid=$pid tid=$tid previewEnabled=$previewEnabled callbackSet=$cbSet")
                    } catch (_: Exception) {}

                    // Safe invocation (we already checked callback != null above)
                    try {
                        previewFrameCallback?.invoke(dataUri)
                        android.util.Log.v("RecordingService", "preview-invoke-success len=${dataUri.length}")
                    } catch (invokeEx: Exception) {
                        android.util.Log.w("RecordingService", "previewFrameCallback invocation failed: ${invokeEx.message}")
                        previewFrameCallback = null
                        previewEnabled = false

                        // Best-effort: request STOP_PREVIEW on main thread
                        try {
                            val stopIntent = Intent(this@RecordingService, RecordingService::class.java).apply { action = "STOP_PREVIEW" }
                            Handler(Looper.getMainLooper()).post {
                                try {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(stopIntent) else startService(stopIntent)
                                } catch (_: Exception) {}
                            }
                        } catch (_: Exception) {}
                    }

                    // Log state after invoking callback
                    try {
                        val pid = android.os.Process.myPid()
                        val tid = android.os.Process.myTid()
                        val cbSet = previewFrameCallback != null
                        android.util.Log.d("RecordingService", "preview-afterInvoke: pid=$pid tid=$tid previewEnabled=$previewEnabled callbackSet=$cbSet")
                    } catch (_: Exception) {}
                } catch (e: Exception) {
                    android.util.Log.w("RecordingService", "preview conversion/dispatch error: ${e.message}")
                }
            }
        }, previewHandler)
    }

    private fun stopRecording() {
        if (!isRecording) {
            stopWithCallback?.invoke(null)
            stopWithCallback = null
            cleanupPreview()
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

        // Clean up preview resources
        cleanupPreview()

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

        if (watermarkEnabled && watermarkImage != null) {
            val wmFile = resolveWatermarkAsset(watermarkImage!!)
            if (wmFile != null) {
                exportWithWatermark(originalFile, wmFile, watermarkPosition) { watermarked ->

                    val finalFile = watermarked ?: originalFile

                    if (saveToGallery) {
                        val finalUri = moveToGallery(finalFile.absolutePath)
                        stopWithCallback?.invoke(finalUri)
                    } else {
                        stopWithCallback?.invoke("file://${finalFile.absolutePath}")
                    }

                    stopWithCallback = null
                    stopForeground(true)
                    stopSelf()
                }
                return
            }
        }

        if (saveToGallery) {
            val finalUri = moveToGallery(originalPath)
            stopWithCallback?.invoke(finalUri)
        } else {
            stopWithCallback?.invoke("file://$originalPath")
        }

        stopWithCallback = null
        stopForeground(true)
        stopSelf()
    }

    private fun cleanupPreview() {
        previewEnabled = false
        previewFrameCallback = null

        try { previewReader?.close() } catch (_: Exception) {}
        previewReader = null

        try {
            previewHandlerThread?.quitSafely()
            previewHandlerThread?.join(200)
        } catch (_: Exception) {}
        previewHandlerThread = null
        previewHandler = null
    }

    private fun enablePreviewForwarding(enable: Boolean) {
        // No-op if already in desired state
        if (enable && previewEnabled) return
        if (!enable && !previewEnabled) return

        previewEnabled = enable

        if (!enable) {
            // Stop forwarding: clear callback and release resources
            previewFrameCallback = null

            try { previewReader?.setOnImageAvailableListener(null, null) } catch (_: Exception) {}
            try { previewReader?.close() } catch (_: Exception) {}
            previewReader = null

            try {
                previewHandlerThread?.quitSafely()
                previewHandlerThread?.join(200)
            } catch (_: Exception) {}
            previewHandlerThread = null
            previewHandler = null

            lastPreviewSentAt = 0L
            return
        }

        // Enabling preview forwarding: ensure handler thread exists
        if (previewHandlerThread == null) {
            previewHandlerThread = HandlerThread("RecordingPreviewThread").apply { start() }
            previewHandler = Handler(previewHandlerThread!!.looper)
        }

        // Ensure a single previewReader exists and install centralized listener
        val previewW = (videoWidth / 3).coerceAtLeast(320)
        val previewH = (videoHeight / 3).coerceAtLeast(180)

        if (previewReader == null) {
            previewReader = ImageReader.newInstance(previewW, previewH, ImageFormat.YUV_420_888, 2)
        }

        // Install the centralized listener (idempotent)
        setPreviewImageAvailableListener(previewReader!!, previewW, previewH)

        // If camera is already open and we have a recorder surface, reconfigure session to include preview surface
        try {
            val recorderSurface = mediaRecorder?.surface
            val previewSurface = previewReader?.surface

            if (cameraDevice != null && previewSurface != null) {
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null

                val targets = mutableListOf<android.view.Surface>()
                recorderSurface?.let { targets.add(it) }
                targets.add(previewSurface)

                cameraDevice?.createCaptureSession(
                    targets,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            captureSession = session
                            try {
                                val requestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                recorderSurface?.let { requestBuilder.addTarget(it) }
                                requestBuilder.addTarget(previewSurface)
                                requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                session.setRepeatingRequest(requestBuilder.build(), null, previewHandler)
                            } catch (e: Exception) {
                                android.util.Log.w("RecordingService", "Failed to set repeating request with preview surface: ${e.message}")
                            }
                        }

                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            android.util.Log.w("RecordingService", "createCaptureSession with preview failed")
                        }
                    },
                    previewHandler
                )
            }
        } catch (e: Exception) {
            android.util.Log.w("RecordingService", "enablePreviewForwarding reconfigure error: ${e.message}")
        }
    }
    
    private fun startPreviewMode() {
        try {
            if (previewEnabled) return
            previewEnabled = true

            // Ensure preview handler thread exists
            if (previewHandlerThread == null) {
                previewHandlerThread = HandlerThread("RecordingPreviewThread").apply { start() }
                previewHandler = Handler(previewHandlerThread!!.looper)
            }

            val previewW = (videoWidth / 3).coerceAtLeast(320)
            val previewH = (videoHeight / 3).coerceAtLeast(180)

            // Create ImageReader if missing and install listener
            if (previewReader == null) {
                previewReader = ImageReader.newInstance(previewW, previewH, ImageFormat.YUV_420_888, 2)
            }
            setPreviewImageAvailableListener(previewReader!!, previewW, previewH)

            // If camera already opened, (re)create a capture session that includes preview surface
            val previewSurface = previewReader?.surface
            val recorderSurface = mediaRecorder?.surface

            if (cameraDevice != null) {
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null

                val targets = mutableListOf<android.view.Surface>()
                recorderSurface?.let { targets.add(it) }
                previewSurface?.let { targets.add(it) }

                if (targets.isEmpty()) return

                cameraDevice?.createCaptureSession(
                    targets,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            captureSession = session
                            try {
                                val requestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                targets.forEach { requestBuilder.addTarget(it) }
                                requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                session.setRepeatingRequest(requestBuilder.build(), null, previewHandler)
                            } catch (e: Exception) {
                                android.util.Log.w("RecordingService", "Failed to set repeating request with preview surface: ${e.message}")
                            }
                        }

                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            android.util.Log.w("RecordingService", "createCaptureSession with preview failed")
                        }
                    },
                    previewHandler
                )
                return
            }

            // If camera not opened yet, open it and create a preview-only session
            val cameraId = try { findCameraIdForFacing(cameraFacing) ?: cameraManager.cameraIdList.firstOrNull() } catch (e: Exception) { null } ?: return

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cameraDevice = device
                    try {
                        val targets = mutableListOf<android.view.Surface>()
                        previewSurface?.let { targets.add(it) }

                        device.createCaptureSession(
                            targets,
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    captureSession = session
                                    try {
                                        val requestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                        previewSurface?.let { requestBuilder.addTarget(it) }
                                        requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                        session.setRepeatingRequest(requestBuilder.build(), null, previewHandler)
                                    } catch (e: Exception) {
                                        android.util.Log.w("RecordingService", "Failed to start preview repeating request: ${e.message}")
                                    }
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    android.util.Log.w("RecordingService", "preview-only createCaptureSession failed")
                                }
                            },
                            previewHandler
                        )
                    } catch (e: Exception) {
                        android.util.Log.w("RecordingService", "Failed to create preview session: ${e.message}")
                    }
                }

                override fun onDisconnected(device: CameraDevice) {
                    try { device.close() } catch (_: Exception) {}
                    cameraDevice = null
                }

                override fun onError(device: CameraDevice, error: Int) {
                    try { device.close() } catch (_: Exception) {}
                    cameraDevice = null
                }
            }, previewHandler)
        } catch (e: Exception) {
            android.util.Log.w("RecordingService", "startPreviewMode error: ${e.message}")
            previewFrameCallback = null
            previewEnabled = false
        }
    }

    private fun stopPreviewMode() {
        try {
            // Disable forwarding and clear callback
            previewEnabled = false
            previewFrameCallback = null

            // Stop any repeating requests that include preview surface
            try { captureSession?.stopRepeating() } catch (_: Exception) {}
            try { captureSession?.abortCaptures() } catch (_: Exception) {}

            // If recording is active, recreate session with only recorder surface
            if (mediaRecorder != null && cameraDevice != null) {
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null
                val recorderSurface = mediaRecorder?.surface
                if (recorderSurface != null) {
                    cameraDevice?.createCaptureSession(
                        listOf(recorderSurface),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                captureSession = session
                                try {
                                    val requestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                    requestBuilder.addTarget(recorderSurface)
                                    requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                    session.setRepeatingRequest(requestBuilder.build(), null, null)
                                } catch (e: Exception) {
                                    android.util.Log.w("RecordingService", "Failed to restore recorder-only session: ${e.message}")
                                }
                            }

                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                android.util.Log.w("RecordingService", "restore recorder-only session failed")
                            }
                        },
                        null
                    )
                }
            } else {
                // Not recording: close capture session and camera device
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null
                try { cameraDevice?.close() } catch (_: Exception) {}
                cameraDevice = null
            }

            // Tear down preview reader and handler thread
            try { previewReader?.setOnImageAvailableListener(null, null) } catch (_: Exception) {}
            try { previewReader?.close() } catch (_: Exception) {}
            previewReader = null

            try {
                previewHandlerThread?.quitSafely()
                previewHandlerThread?.join(200)
            } catch (_: Exception) {}
            previewHandlerThread = null
            previewHandler = null

            lastPreviewSentAt = 0L
        } catch (e: Exception) {
            android.util.Log.w("RecordingService", "stopPreviewMode error: ${e.message}")
        }
    }


    // Helper to move file to gallery (unchanged behavior)
    private fun moveToGallery(path: String): String? {
        return try {
            val file = File(path)
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            if (uri != null) {
                resolver.openOutputStream(uri).use { out ->
                    FileInputStream(file).use { input ->
                        input.copyTo(out!!)
                    }
                }
                uri.toString()
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }
}
