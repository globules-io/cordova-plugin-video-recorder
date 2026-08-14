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
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.hardware.camera2.*
import android.media.Image
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import androidx.core.app.NotificationCompat
import com.arthenica.ffmpegkit.FFmpegKit
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.text.SimpleDateFormat
import java.util.*

class RecordingService : Service() {

    companion object {
        var stopWithCallback: ((String?) -> Unit)? = null
        private const val CHANNEL_ID = "video_recorder_channel"
        private const val TAG = "RecordingService"

        @Volatile
        var previewFrameCallback: ((String) -> Unit)? = null
    }

    private lateinit var cameraManager: CameraManager
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var mediaRecorder: MediaRecorder? = null
    private var outputFile: String? = null

    // ---------- Recording settings (independent) ----------
    private var videoWidth = 1920
    private var videoHeight = 1080
    private var videoBitrate = 10_000_000
    private var maxLengthSec = 0
    private var isRecording = false
    private var cameraFacing: Int = CameraCharacteristics.LENS_FACING_BACK
    private var saveToGallery: Boolean = false

    // WATERMARK
    private var watermarkEnabled = false
    private var watermarkImage: String? = null
    private var watermarkPosition: String = "bottomright"

    // Preview fields
    private var previewEnabled = false
    private var previewReader: ImageReader? = null
    private var previewHandlerThread: HandlerThread? = null
    private var previewHandler: Handler? = null
    private var lastPreviewSentAt = 0L

    private var previewWidth = 1280
    private var previewHeight = 720
    private var previewTargetFps = 15
    private var previewJpegQuality = 95      
    private var previewCameraFacing: Int = CameraCharacteristics.LENS_FACING_BACK

    // ---------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        createNotificationChannel()
        val notification = buildNotification()

        val hasCameraPermission = androidx.core.content.ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.CAMERA
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && hasCameraPermission) {
            try {
                startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            } catch (se: SecurityException) {
                Log.w(TAG, "startForeground with camera type denied, falling back: ${se.message}")
                startForeground(1, notification)
            }
        } else {
            startForeground(1, notification)
        }

        Log.d(TAG, "onCreate: pid=${android.os.Process.myPid()}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (intent == null) {
                Log.w(TAG, "onStartCommand: null intent")
                return START_STICKY
            }

            when (intent.action) {
                "START_RECORDING" -> {
                    try {
                        val resolution = intent.getStringExtra("resolution") ?: "${videoWidth}x${videoHeight}"
                        val bitrate = intent.getIntExtra("bitrate", videoBitrate)
                        val maxLength = intent.getIntExtra("maxLength", maxLengthSec)
                        val camera = intent.getStringExtra("camera") ?: if (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT) "front" else "back"
                        saveToGallery = intent.getBooleanExtra("saveToGallery", saveToGallery)

                        watermarkEnabled = intent.getBooleanExtra("watermarkEnabled", watermarkEnabled)
                        watermarkImage = intent.getStringExtra("watermarkImage") ?: watermarkImage
                        watermarkPosition = intent.getStringExtra("watermarkPosition") ?: watermarkPosition

                        parseResolution(resolution, isPreview = false)
                        videoBitrate = bitrate
                        maxLengthSec = maxLength
                        cameraFacing = if (camera.lowercase(Locale.US) == "front") {
                            CameraCharacteristics.LENS_FACING_FRONT
                        } else {
                            CameraCharacteristics.LENS_FACING_BACK
                        }

                        startCameraRecording()
                    } catch (e: Exception) {
                        Log.w(TAG, "START_RECORDING failed: ${e.message}")
                    }
                    return START_STICKY
                }

                "STOP_RECORDING" -> {
                    try { stopRecording() } catch (e: Exception) {
                        Log.w(TAG, "STOP_RECORDING failed: ${e.message}")
                    }
                    return START_NOT_STICKY
                }

                "START_PREVIEW" -> {
                    try {
                        val camera = intent.getStringExtra("camera") ?: "back"
                        val resolution = intent.getStringExtra("resolution") ?: "1280x720"
                        val fps = intent.getIntExtra("fps", 15)

                        previewCameraFacing = if (camera.lowercase(Locale.US) == "front") {
                            CameraCharacteristics.LENS_FACING_FRONT
                        } else {
                            CameraCharacteristics.LENS_FACING_BACK
                        }

                        parseResolution(resolution, isPreview = true)
                        previewTargetFps = if (fps > 0) fps else 15
                        // No quality parameter any more

                        Log.d(TAG, "START_PREVIEW: ${previewWidth}x${previewHeight} @ ${previewTargetFps}fps")
                        startPreviewMode()
                    } catch (e: Exception) {
                        Log.w(TAG, "START_PREVIEW failed: ${e.message}")
                    }
                    return START_STICKY
                }

                "STOP_PREVIEW" -> {
                    try { stopPreviewMode() } catch (e: Exception) {
                        Log.w(TAG, "STOP_PREVIEW failed: ${e.message}")
                    }
                    return START_NOT_STICKY
                }

                else -> {
                    Log.w(TAG, "Unknown action: ${intent.action}")
                    return START_NOT_STICKY
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "onStartCommand fatal: ${e.message}", e)
            try {
                stopPreviewMode()
                stopRecording()
            } catch (_: Exception) {}
            return START_NOT_STICKY
        }
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------

    private fun parseResolution(resolution: String, isPreview: Boolean) {
        val parts = resolution.lowercase(Locale.US).split("x")
        if (parts.size == 2) {
            val w = parts[0].toIntOrNull()
            val h = parts[1].toIntOrNull()
            if (w != null && h != null && w > 0 && h > 0) {
                if (isPreview) {
                    previewWidth = w
                    previewHeight = h
                } else {
                    videoWidth = w
                    videoHeight = h
                }
            }
        }
    }

    private fun findCameraIdForFacing(facing: Int): String? {
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == facing) return id
        }
        return null
    }

    /**
     * Choose best supported size for a given output class (MediaRecorder or ImageFormat).
     */
    private fun chooseBestSize(
        cameraId: String?,
        requestedW: Int,
        requestedH: Int,
        outputClass: Class<*>? = null,
        imageFormat: Int? = null
    ): Size? {
        try {
            val id = cameraId ?: return null
            val chars = cameraManager.getCameraCharacteristics(id)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return null

            val sizes: Array<Size> = when {
                outputClass != null -> map.getOutputSizes(outputClass) ?: emptyArray()
                imageFormat != null -> map.getOutputSizes(imageFormat) ?: emptyArray()
                else -> emptyArray()
            }
            if (sizes.isEmpty()) return null

            // Exact match
            sizes.firstOrNull { it.width == requestedW && it.height == requestedH }?.let {
                Log.d(TAG, "chooseBestSize: exact match ${it.width}x${it.height}")
                return it
            }
            // Rotated exact match
            sizes.firstOrNull { it.width == requestedH && it.height == requestedW }?.let {
                Log.d(TAG, "chooseBestSize: rotated exact ${it.width}x${it.height}")
                return it
            }

            val reqAspect = requestedW.toFloat() / requestedH          // < 1 for portrait
            val reqArea   = requestedW.toLong() * requestedH

            // Score every size: aspect-ratio difference is the most important factor
            fun score(s: Size): Double {
                val aspect = s.width.toFloat() / s.height
                val aspectDiff = kotlin.math.abs(aspect - reqAspect)

                // Also consider the rotated aspect (camera sensors are usually landscape)
                val rotatedAspect = s.height.toFloat() / s.width
                val rotatedDiff = kotlin.math.abs(rotatedAspect - reqAspect)

                val bestAspectDiff = minOf(aspectDiff, rotatedDiff)

                val area = s.width.toLong() * s.height
                val areaDiff = kotlin.math.abs(area - reqArea).toDouble() / reqArea

                // Heavy weight on aspect ratio, lighter weight on area
                return bestAspectDiff * 10.0 + areaDiff
            }

            val best = sizes.minByOrNull { score(it) }
            if (best != null) {
                Log.d(TAG, "chooseBestSize: best aspect match ${best.width}x${best.height} " +
                        "(requested ${requestedW}x${requestedH}, score=${score(best)})")
            }            
            return best
        } catch (e: Exception) {
            Log.w(TAG, "chooseBestSize error: ${e.message}")
            return null
        }
    }

    // ----------------------------------------------------------------------
    // Recording path
    // ----------------------------------------------------------------------

    private fun startCameraRecording() {
        try {
            val cameraId = findCameraIdForFacing(cameraFacing)
                ?: cameraManager.cameraIdList.firstOrNull() ?: return

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
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
            }, null)
        } catch (e: SecurityException) {
            stopSelf()
        }
    }

    private fun setupMediaRecorder() {
        val dir = getExternalFilesDir(Environment.DIRECTORY_MOVIES)
        if (dir != null && !dir.exists()) dir.mkdirs()

        val cameraId = findCameraIdForFacing(cameraFacing)
        val chosen = chooseBestSize(cameraId, videoWidth, videoHeight, MediaRecorder::class.java)
        if (chosen != null) {
            if (chosen.width != videoWidth || chosen.height != videoHeight) {
                Log.d(TAG, "setupMediaRecorder: ${videoWidth}x${videoHeight} ? ${chosen.width}x${chosen.height}")
                videoWidth = chosen.width
                videoHeight = chosen.height
            }
        }

        val ts = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val file = File(dir, "VID_$ts.mp4")
        outputFile = file.absolutePath

        mediaRecorder = MediaRecorder().apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setVideoSource(MediaRecorder.VideoSource.SURFACE)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setOutputFile(outputFile)
            setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setVideoEncodingBitRate(videoBitrate)
            setVideoFrameRate(30)
            setVideoSize(videoWidth, videoHeight)

            if (maxLengthSec > 0) setMaxDuration(maxLengthSec * 1000)

            setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) {
                    stopRecording()
                }
            }

            // Orientation hint
            try {
                val camId = findCameraIdForFacing(cameraFacing)
                val chars = camId?.let { cameraManager.getCameraCharacteristics(it) }
                val sensorOrientation = chars?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
                val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
                val degrees = when (wm.defaultDisplay.rotation) {
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
                setOrientationHint(orientationHint)
            } catch (e: Exception) {
                Log.w(TAG, "orientation hint failed: ${e.message}")
            }

            try {
                prepare()
            } catch (e: Exception) {
                Log.e(TAG, "MediaRecorder.prepare failed: ${e.message}")
                throw e
            }
        }
    }

    private fun createCaptureSession() {
        val surface = mediaRecorder!!.surface
        val camId = findCameraIdForFacing(cameraFacing)

        // Build targets
        val targets = mutableListOf(surface)

        // If preview is already running, include its surface (different resolution!)
        if (previewEnabled && previewReader != null) {
            previewReader?.surface?.let { targets.add(it) }
        }

        Log.d(TAG, "createCaptureSession: recording ${videoWidth}x${videoHeight}, previewEnabled=$previewEnabled targets=${targets.size}")

        fun doCreateSession(targetSurfaces: List<android.view.Surface>) {
            try {
                cameraDevice?.createCaptureSession(
                    targetSurfaces,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            captureSession = session
                            try {
                                val requestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                targetSurfaces.forEach { requestBuilder.addTarget(it) }
                                requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                session.setRepeatingRequest(requestBuilder.build(), null, previewHandler)
                                mediaRecorder?.start()
                                isRecording = true
                                Log.d(TAG, "recording started")
                            } catch (e: Exception) {
                                Log.w(TAG, "onConfigured failed: ${e.message}")
                                stopSelf()
                            }
                        }

                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            Log.w(TAG, "onConfigureFailed – retrying without preview")
                            if (previewEnabled && targetSurfaces.size > 1) {
                                try {
                                    captureSession?.close()
                                    doCreateSession(listOf(surface))
                                } catch (e: Exception) {
                                    stopSelf()
                                }
                            } else {
                                stopSelf()
                            }
                        }
                    },
                    previewHandler
                )
            } catch (e: Exception) {
                Log.w(TAG, "createCaptureSession threw: ${e.message}")
                if (previewEnabled) {
                    try { doCreateSession(listOf(surface)) } catch (_: Exception) { stopSelf() }
                } else {
                    stopSelf()
                }
            }
        }

        doCreateSession(targets)
    }

    // ----------------------------------------------------------------------
    // Preview path (independent)
    // ----------------------------------------------------------------------

    private fun startPreviewMode() {
        try {
            if (previewEnabled) return
            previewEnabled = true

            if (previewHandlerThread == null) {
                previewHandlerThread = HandlerThread("PreviewThread").apply { start() }
                previewHandler = Handler(previewHandlerThread!!.looper)
            }

            val cameraId = findCameraIdForFacing(previewCameraFacing)
                ?: cameraManager.cameraIdList.firstOrNull() ?: return

            // Choose a real supported size (prefer exact / rotated match)
            val best = chooseBestSize(
                cameraId,
                previewWidth,
                previewHeight,
                imageFormat = ImageFormat.YUV_420_888
            )
            if (best != null) {
                previewWidth = best.width
                previewHeight = best.height
                Log.d(TAG, "preview chosen size = ${previewWidth}x${previewHeight}")
            }

            if (previewReader == null) {
                previewReader = ImageReader.newInstance(
                    previewWidth, previewHeight,
                    ImageFormat.YUV_420_888, 2
                )
            }
            setPreviewImageAvailableListener(previewReader!!)

            val previewSurface = previewReader!!.surface

            // Case 1 – camera already open (recording is active)
            if (cameraDevice != null) {
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null

                val targets = mutableListOf<android.view.Surface>()
                mediaRecorder?.surface?.let { targets.add(it) }
                targets.add(previewSurface)

                cameraDevice?.createCaptureSession(
                    targets,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            captureSession = session
                            try {
                                val template = if (isRecording)
                                    CameraDevice.TEMPLATE_RECORD
                                else
                                    CameraDevice.TEMPLATE_PREVIEW
                                val requestBuilder = cameraDevice!!.createCaptureRequest(template)
                                targets.forEach { requestBuilder.addTarget(it) }
                                requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                session.setRepeatingRequest(requestBuilder.build(), null, previewHandler)
                            } catch (e: Exception) {
                                Log.w(TAG, "Failed to set repeating request with preview: ${e.message}")
                            }
                        }
                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            Log.w(TAG, "preview reconfigure failed")
                        }
                    },
                    previewHandler
                )
                return
            }

            // Case 2 – preview only
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cameraDevice = device
                    try {
                        device.createCaptureSession(
                            listOf(previewSurface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    captureSession = session
                                    try {
                                        val requestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                        requestBuilder.addTarget(previewSurface)
                                        requestBuilder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                        session.setRepeatingRequest(requestBuilder.build(), null, previewHandler)
                                    } catch (e: Exception) {
                                        Log.w(TAG, "preview repeating request failed: ${e.message}")
                                    }
                                }
                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    Log.w(TAG, "preview-only session failed")
                                }
                            },
                            previewHandler
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "create preview session failed: ${e.message}")
                    }
                }
                override fun onDisconnected(device: CameraDevice) {
                    device.close()
                    cameraDevice = null
                }
                override fun onError(device: CameraDevice, error: Int) {
                    device.close()
                    cameraDevice = null
                }
            }, previewHandler)
        } catch (e: Exception) {
            Log.w(TAG, "startPreviewMode error: ${e.message}")
            previewFrameCallback = null
            previewEnabled = false
        }
    }

    private fun setPreviewImageAvailableListener(reader: ImageReader) {
        try { reader.setOnImageAvailableListener(null, null) } catch (_: Exception) {}

        reader.setOnImageAvailableListener({ r ->
            val image = try { r.acquireLatestImage() } catch (_: Exception) { null }
                ?: return@setOnImageAvailableListener

            try {
                if (!previewEnabled || previewFrameCallback == null) {
                    image.close()
                    return@setOnImageAvailableListener
                }

                val now = System.currentTimeMillis()
                val minInterval = if (previewTargetFps > 0) 1000L / previewTargetFps else 0L
                if (minInterval > 0 && now - lastPreviewSentAt < minInterval) {
                    image.close()
                    return@setOnImageAvailableListener
                }
                lastPreviewSentAt = now

                val nv21 = yuv420ToNv21(image)
                val width = image.width
                val height = image.height
                image.close()

                if (nv21 == null) return@setOnImageAvailableListener

                previewHandler?.post {
                    if (!previewEnabled || previewFrameCallback == null) return@post
                    try {
                        // Single high-quality JPEG + correct orientation
                        val jpegBytes = nv21ToJpeg(nv21, width, height, previewJpegQuality)
                        val finalJpeg = applySensorOrientation(jpegBytes)
                        val b64 = android.util.Base64.encodeToString(finalJpeg, android.util.Base64.NO_WRAP)
                        previewFrameCallback?.invoke("data:image/jpeg;base64,$b64")
                    } catch (e: Exception) {
                        Log.w(TAG, "preview conversion failed: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                try { image.close() } catch (_: Exception) {}
                Log.w(TAG, "onImageAvailable error: ${e.message}")
            }
        }, previewHandler)
    }

    private fun nv21ToJpeg(nv21: ByteArray, width: Int, height: Int, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)
        return out.toByteArray()
    }

    // Simplified – only rotates when needed, no second quality loss when rotation == 0
    private fun applySensorOrientation(jpegBytes: ByteArray): ByteArray {
        return try {
            val cameraId = findCameraIdForFacing(previewCameraFacing) ?: return jpegBytes
            val chars = cameraManager.getCameraCharacteristics(cameraId)
            val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val facing = chars.get(CameraCharacteristics.LENS_FACING)

            val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
            val displayRotation = when (wm.defaultDisplay.rotation) {
                android.view.Surface.ROTATION_0   -> 0
                android.view.Surface.ROTATION_90  -> 90
                android.view.Surface.ROTATION_180 -> 180
                android.view.Surface.ROTATION_270 -> 270
                else -> 0
            }

            var rotation = if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
                (sensorOrientation + displayRotation) % 360
            } else {
                (sensorOrientation - displayRotation + 360) % 360
            }

            // Portrait adjustment (common for front cameras)
            if (previewWidth < previewHeight && (rotation == 0 || rotation == 180)) {
                rotation = (rotation + 90) % 360
            }

            if (rotation == 0 && facing != CameraCharacteristics.LENS_FACING_FRONT) {
                return jpegBytes
            }

            val bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size) ?: return jpegBytes
            val matrix = Matrix()
            matrix.postRotate(rotation.toFloat())
            if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
                matrix.postScale(-1f, 1f)          // mirror
            }

            val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            bitmap.recycle()

            val out = ByteArrayOutputStream()
            // Keep the same high quality
            rotated.compress(Bitmap.CompressFormat.JPEG, previewJpegQuality, out)
            rotated.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            Log.w(TAG, "applySensorOrientation failed: ${e.message}")
            jpegBytes
        }
    }

    private fun stopPreviewMode() {
        try {
            previewEnabled = false
            previewFrameCallback = null

            try { captureSession?.stopRepeating() } catch (_: Exception) {}
            try { captureSession?.abortCaptures() } catch (_: Exception) {}

            // If we are still recording, restore recorder-only session
            if (isRecording && mediaRecorder != null && cameraDevice != null) {
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null
                val recorderSurface = mediaRecorder!!.surface
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
                                Log.w(TAG, "restore recorder-only failed: ${e.message}")
                            }
                        }
                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            Log.w(TAG, "restore recorder-only configure failed")
                        }
                    },
                    null
                )
            } else {
                // Not recording ? close everything
                try { captureSession?.close() } catch (_: Exception) {}
                captureSession = null
                try { cameraDevice?.close() } catch (_: Exception) {}
                cameraDevice = null
            }

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
            Log.w(TAG, "stopPreviewMode error: ${e.message}")
        }
    }

    private fun cleanupPreview() {
        stopPreviewMode()
    }

    private fun yuv420ToNv21(image: Image): ByteArray? {
        return try {
            val width = image.width
            val height = image.height
            val ySize = width * height
            val uvSize = width * height / 2
            val nv21 = ByteArray(ySize + uvSize)

            val yBuffer = image.planes[0].buffer
            val uBuffer = image.planes[1].buffer
            val vBuffer = image.planes[2].buffer

            val yRowStride = image.planes[0].rowStride
            val yPixelStride = image.planes[0].pixelStride
            val uRowStride = image.planes[1].rowStride
            val uPixelStride = image.planes[1].pixelStride
            val vRowStride = image.planes[2].rowStride
            val vPixelStride = image.planes[2].pixelStride

            // Copy Y plane
            var pos = 0
            if (yRowStride == width && yPixelStride == 1) {
                yBuffer.get(nv21, 0, ySize)
                pos = ySize
            } else {
                for (row in 0 until height) {
                    val yPos = row * yRowStride
                    for (col in 0 until width) {
                        nv21[pos++] = yBuffer.get(yPos + col * yPixelStride)
                    }
                }
            }

            // Interleave V and U (NV21 = YYYY VU VU ...)
            val chromaHeight = height / 2
            val chromaWidth = width / 2

            for (row in 0 until chromaHeight) {
                val vRowStart = row * vRowStride
                val uRowStart = row * uRowStride
                for (col in 0 until chromaWidth) {
                    val vIndex = vRowStart + col * vPixelStride
                    val uIndex = uRowStart + col * uPixelStride
                    nv21[pos++] = vBuffer.get(vIndex)   // V
                    nv21[pos++] = uBuffer.get(uIndex)   // U
                }
            }
            nv21
        } catch (e: Exception) {
            Log.w(TAG, "yuv420ToNv21 failed: ${e.message}")
            null
        }
    }
   
    // ----------------------------------------------------------------------
    // Stop recording + watermark + gallery
    // ----------------------------------------------------------------------

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
                        stopWithCallback?.invoke(moveToGallery(finalFile.absolutePath))
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
            stopWithCallback?.invoke(moveToGallery(originalPath))
        } else {
            stopWithCallback?.invoke("file://$originalPath")
        }
        stopWithCallback = null
        stopForeground(true)
        stopSelf()
    }

    // ----------------------------------------------------------------------
    // Watermark / gallery helpers
    // ----------------------------------------------------------------------

    private fun resolveWatermarkAsset(relativePath: String): File? {
        return try {
            val input = assets.open("www/$relativePath")
            val temp = File(cacheDir, "wm_${System.currentTimeMillis()}.png")
            input.copyTo(temp.outputStream())
            temp
        } catch (e: Exception) { null }
    }

    private fun ffmpegOverlayPosition(pos: String): String = when (pos.lowercase()) {
        "topleft" -> "10:10"
        "topright" -> "main_w-overlay_w-10:10"
        "bottomleft" -> "10:main_h-overlay_h-10"
        else -> "main_w-overlay_w-10:main_h-overlay_h-10"
    }

    private fun exportWithWatermark(input: File, watermark: File, position: String, callback: (File?) -> Unit) {
        val output = File(cacheDir, "VID_WM_${System.currentTimeMillis()}.mp4")
        val overlayPos = ffmpegOverlayPosition(position)
        val cmd = arrayOf(
            "-i", input.absolutePath,
            "-i", watermark.absolutePath,
            "-filter_complex", "overlay=$overlayPos",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18",
            "-c:a", "copy",
            output.absolutePath
        )
        FFmpegKit.executeAsync(cmd.joinToString(" ")) { session ->
            callback(if (session.returnCode.isValueSuccess) output else null)
        }
    }

    private fun moveToGallery(path: String): String? {
        return try {
            val file = File(path)
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES)
            }
            val uri = contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            if (uri != null) {
                contentResolver.openOutputStream(uri).use { out ->
                    FileInputStream(file).use { it.copyTo(out!!) }
                }
                uri.toString()
            } else null
        } catch (e: Exception) { null }
    }

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
            val chan = NotificationChannel(CHANNEL_ID, "Video Recorder", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(chan)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}