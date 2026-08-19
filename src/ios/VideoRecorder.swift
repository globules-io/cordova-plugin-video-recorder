import Foundation
import AVFoundation
import Photos
import Cordova
import UIKit

@objc(VideoRecorder)
class VideoRecorder: CDVPlugin {

    //  Recording state
    var captureSession: AVCaptureSession?
    var movieOutput: AVCaptureMovieFileOutput?
    var outputUrl: URL?
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var callbackId: String?

    var maxLengthSec: Int = 0
    var videoWidth: Int = 1920
    var videoHeight: Int = 1080
    var bitrate: Int = 10_000_000
    var stopTimer: Timer?
    var cameraPosition: AVCaptureDevice.Position = .back
    var saveToGallery: Bool = false

    // Watermark
    var watermarkEnabled: Bool = false
    var watermarkImage: String?
    var watermarkPosition: String = "bottomright"

    //  Preview state (independent)
    private var previewSession: AVCaptureSession?
    private var previewVideoOutput: AVCaptureVideoDataOutput?
    private var previewQueue: DispatchQueue?
    private var previewCallbackId: String?
    private var previewEnabled: Bool = false
    private var previewTargetFps: Int = 10
    private var lastPreviewSentAt: TimeInterval = 0
    private var ciContext: CIContext? = CIContext(options: [.useSoftwareRenderer: false])

    private var previewWidth: Int = 1280
    private var previewHeight: Int = 720
    private var previewCameraPosition: AVCaptureDevice.Position = .back
    private var previewJpegQuality: CGFloat = 0.85

    private let previewMaxLongSide = 1280

    // Frame counter for logging (reset on each start)
    private var previewFrameCount: Int = 0

    // Dedicated queue for recording session work
    private let recordingQueue = DispatchQueue(label: "VideoRecorder.RecordingQueue", qos: .userInitiated)

    //  Cordova actions

    @objc(start:)
    func start(command: CDVInvokedUrlCommand) {
        self.callbackId = command.callbackId

        let options = command.arguments.first as? [String: Any] ?? [:]

        maxLengthSec = options["maxLength"] as? Int ?? 0
        bitrate = options["bitrate"] as? Int ?? 10_000_000
        saveToGallery = options["saveToGallery"] as? Bool ?? false

        if let res = options["resolution"] as? String {
            let parts = res.lowercased().split(separator: "x")
            if parts.count == 2,
               let w = Int(parts[0]), let h = Int(parts[1]),
               w > 0, h > 0 {
                videoWidth = w
                videoHeight = h
            }
        }

        if let cam = options["camera"] as? String {
            cameraPosition = cam.lowercased() == "front" ? .front : .back
        }

        if let wm = options["watermark"] as? [String: Any] {
            watermarkEnabled = true
            watermarkImage = wm["image"] as? String
            watermarkPosition = (wm["position"] as? String) ?? "bottomright"
        } else {
            watermarkEnabled = false
            watermarkImage = nil
        }

        NSLog("[VideoRecorder] start called, maxLength=\(maxLengthSec), requested=\(videoWidth)x\(videoHeight), camera=\(cameraPosition == .front ? "front" : "back"), saveToGallery=\(saveToGallery), watermark=\(watermarkEnabled)")

        startBackgroundTask()

        // Move session setup + startRecording onto a background queue
        recordingQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupSession()
            self.startRecording()
        }

        let result = CDVPluginResult(status: .ok)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    @objc(stop:)
    func stop(command: CDVInvokedUrlCommand) {
        NSLog("[VideoRecorder] stop called")
        self.callbackId = command.callbackId
        stopRecording()
    }

    //  Preview actions

    @objc(preview:)
    func preview(command: CDVInvokedUrlCommand) {
        let arg = command.arguments.first
        NSLog("[VideoRecorder] preview() called with arg type: \(type(of: arg)) value: \(String(describing: arg))")

        if arg is [String: Any] {
            previewStart(command: command)
            return
        }

        if let boolArg = arg as? Bool {
            boolArg ? previewStart(command: command) : previewStop(command: command)
            return
        }

        if let strArg = arg as? String {
            let lower = strArg.lowercased()
            if lower == "start" { previewStart(command: command); return }
            if lower == "stop"  { previewStop(command: command); return }
        }

        if let arr = arg as? [Any], let first = arr.first {
            if let b = first as? Bool {
                b ? previewStart(command: command) : previewStop(command: command)
                return
            }
            if let s = first as? String {
                let lower = s.lowercased()
                if lower == "start" { previewStart(command: command); return }
                if lower == "stop"  { previewStop(command: command); return }
            }
            if first is [String: Any] {
                previewStart(command: command)
                return
            }
        }

        previewEnabled ? previewStop(command: command) : previewStart(command: command)
    }

   @objc(previewStart:)
     func previewStart(command: CDVInvokedUrlCommand) {
          let options = command.arguments.first as? [String: Any] ?? [:]

          if let fps = options["fps"] as? Int, fps > 0 {
               previewTargetFps = fps
          }
          if let quality = options["quality"] as? Int {
               previewJpegQuality = CGFloat(max(1, min(100, quality))) / 100.0
          }
          if let cam = options["camera"] as? String {
               previewCameraPosition = cam.lowercased() == "front" ? .front : .back
          }
          if let res = options["resolution"] as? String {
               let parts = res.lowercased().split(separator: "x")
               if parts.count == 2,
                    let w = Int(parts[0]), let h = Int(parts[1]),
                    w > 0, h > 0 {
                    previewWidth = w
                    previewHeight = h
               }
          }

          NSLog("[VideoRecorder] previewStart called fps=\(previewTargetFps), quality=\(previewJpegQuality), camera=\(previewCameraPosition == .front ? "front" : "back"), res=\(previewWidth)x\(previewHeight), callbackId=\(command.callbackId ?? "nil")")

          // Always take ownership of the new callback id
          previewCallbackId = command.callbackId

          DispatchQueue.main.async { [weak self] in
               guard let self = self else { return }

               // Clean stop first
               NSLog("[VideoRecorder] previewStart: forcing clean stop before restart")
               self.stopPreviewSession()

               // NOW set the flag
               self.previewEnabled = true
               self.lastPreviewSentAt = 0
               self.previewFrameCount = 0

               let startResult = CDVPluginResult(status: .ok, messageAs: "preview_started")
               startResult.setKeepCallbackAs(true)
               if let cb = self.previewCallbackId {
                    self.commandDelegate.send(startResult, callbackId: cb)
                    NSLog("[VideoRecorder] Sent 'preview_started' to JS")
               } else {
                    NSLog("[VideoRecorder] WARNING: previewCallbackId is nil after assignment!")
               }

               // setupPreviewSession must NOT call stopPreviewSession again
               self.setupPreviewSession()
          }
     }

    @objc(previewStop:)
    func previewStop(command: CDVInvokedUrlCommand) {
        NSLog("[VideoRecorder] previewStop called  current previewEnabled=\(previewEnabled), frames sent so far=\(previewFrameCount)")

        stopPreviewSession()

        let stopResult = CDVPluginResult(status: .ok, messageAs: "preview_stopped")
        stopResult.setKeepCallbackAs(false)

        if let cb = command.callbackId {
            commandDelegate.send(stopResult, callbackId: cb)
            NSLog("[VideoRecorder] Sent 'preview_stopped' using command.callbackId")
        } else if let cb = previewCallbackId {
            commandDelegate.send(stopResult, callbackId: cb)
            NSLog("[VideoRecorder] Sent 'preview_stopped' using stored previewCallbackId")
        } else {
            NSLog("[VideoRecorder] WARNING: no callback id available to send preview_stopped")
        }
        previewCallbackId = nil
    }

    //  Recording

    private func setupSession() {
        NSLog("[VideoRecorder] setupSession for recording (on background queue)")
        let session = AVCaptureSession()
        captureSession = session
        session.beginConfiguration()

        if videoWidth >= 3840 || videoHeight >= 2160 {
            session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
        } else if videoWidth >= 1920 || videoHeight >= 1080 {
            session.sessionPreset = .hd1920x1080
        } else if videoWidth >= 1280 || videoHeight >= 720 {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .vga640x480
        }

        var videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)
        if videoDevice == nil {
            videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }

        guard let vDevice = videoDevice,
              let videoInput = try? AVCaptureDeviceInput(device: vDevice),
              session.canAddInput(videoInput) else {
            NSLog("[VideoRecorder] ERROR: failed to add video input for recording")
            session.commitConfiguration()
            return
        }
        session.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            NSLog("[VideoRecorder] Audio input added")
        } else {
            NSLog("[VideoRecorder] WARNING: no audio input")
        }

        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            self.movieOutput = movieOutput
            NSLog("[VideoRecorder] Movie output added")
        }

        session.commitConfiguration()
        NSLog("[VideoRecorder] Recording session configured")
    }

    private func startRecording() {
        guard let movieOutput = movieOutput,
              let session = captureSession else {
            NSLog("[VideoRecorder] ERROR: startRecording missing movieOutput or session")
            return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileUrl = docs.appendingPathComponent("VID_\(formatter.string(from: Date())).mov")
        outputUrl = fileUrl

        NSLog("[VideoRecorder] Starting recording to \(fileUrl.lastPathComponent)")

        // Audio session must be configured on the main thread
        DispatchQueue.main.sync {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }

        if let connection = movieOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        if maxLengthSec > 0 {
            movieOutput.maxRecordedDuration = CMTime(seconds: Double(maxLengthSec), preferredTimescale: 600)

            // Timer must be scheduled on the main run loop
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.stopTimer = Timer(timeInterval: Double(self.maxLengthSec) + 0.5, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    NSLog("[VideoRecorder] maxLength timer fired stopping recording")
                    self.stopRecording()
                }
                if let t = self.stopTimer {
                    RunLoop.main.add(t, forMode: .common)
                }
            }
        }

        // startRunning can block already running on recordingQueue
        session.startRunning()
        movieOutput.startRecording(to: fileUrl, recordingDelegate: self)
        NSLog("[VideoRecorder] Recording started (session.isRunning=\(session.isRunning))")
    }

    private func stopRecording() {
        NSLog("[VideoRecorder] stopRecording called")
        if let timer = stopTimer {
            timer.invalidate()
        }
        stopTimer = nil

        // Perform stop on the recording queue to keep it off the main thread
        recordingQueue.async { [weak self] in
            guard let self = self else { return }

            guard let movieOutput = self.movieOutput else {
                NSLog("[VideoRecorder] stopRecording no movieOutput")
                return
            }
            if movieOutput.isRecording {
                movieOutput.stopRecording()
                NSLog("[VideoRecorder] movieOutput.stopRecording() called")
            } else {
                NSLog("[VideoRecorder] movieOutput was not recording")
            }
        }
    }

    //  Preview session

    private func setupPreviewSession() {
          NSLog("[VideoRecorder] setupPreviewSession starting (previewEnabled=\(previewEnabled))")

          // IMPORTANT: Do NOT call stopPreviewSession() here!
          // previewStart already did a clean stop.

          let session = AVCaptureSession()
          session.beginConfiguration()

          let requestedLong = max(previewWidth, previewHeight)
          let targetLong = min(requestedLong, previewMaxLongSide)

          if targetLong >= 1920 && session.canSetSessionPreset(.hd1920x1080) {
               session.sessionPreset = .hd1920x1080
               NSLog("[VideoRecorder] Preview preset: 1920x1080")
          } else if targetLong >= 1280 && session.canSetSessionPreset(.hd1280x720) {
               session.sessionPreset = .hd1280x720
               NSLog("[VideoRecorder] Preview preset: 1280x720")
          } else if session.canSetSessionPreset(.vga640x480) {
               session.sessionPreset = .vga640x480
               NSLog("[VideoRecorder] Preview preset: 640x480")
          } else {
               session.sessionPreset = .high
               NSLog("[VideoRecorder] Preview preset: .high")
          }

          guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: previewCameraPosition),
                    let input = try? AVCaptureDeviceInput(device: device),
                    session.canAddInput(input) else {
               NSLog("[VideoRecorder] ERROR: Preview failed to create camera input (position=\(previewCameraPosition == .front ? "front" : "back"))")
               session.commitConfiguration()

               if let cb = previewCallbackId {
                    let err = CDVPluginResult(status: .error, messageAs: "preview_camera_unavailable")
                    commandDelegate.send(err, callbackId: cb)
               }
               previewEnabled = false
               return
          }
          session.addInput(input)
          NSLog("[VideoRecorder] Preview camera input added")

          let videoOutput = AVCaptureVideoDataOutput()
          videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
          videoOutput.alwaysDiscardsLateVideoFrames = true

          let queue = DispatchQueue(label: "VideoRecorderPreviewQueue", qos: .userInitiated)
          guard session.canAddOutput(videoOutput) else {
               NSLog("[VideoRecorder] ERROR: Preview  cannot add video output")
               session.commitConfiguration()
               previewEnabled = false
               return
          }
          session.addOutput(videoOutput)
          videoOutput.setSampleBufferDelegate(self, queue: queue)
          NSLog("[VideoRecorder] Preview video output added + delegate set")

          if let connection = videoOutput.connection(with: .video) {
               if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
               }
               if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = (previewCameraPosition == .front)
               }
               NSLog("[VideoRecorder] Preview connection configured (mirrored=\(connection.isVideoMirrored))")
          }

          session.commitConfiguration()

          previewSession = session
          previewVideoOutput = videoOutput
          previewQueue = queue

          DispatchQueue.global(qos: .userInitiated).async { [weak self] in
               guard let self = self else { return }

               // Final safety check
               guard self.previewEnabled else {
                    NSLog("[VideoRecorder] Preview startRunning aborted  previewEnabled is false")
                    return
               }

               session.startRunning()
               NSLog("[VideoRecorder] Preview session startRunning() finished  isRunning=\(session.isRunning)")
          }
}

    private func stopPreviewSession() {
        let wasEnabled = previewEnabled
        previewEnabled = false

        NSLog("[VideoRecorder] stopPreviewSession  wasEnabled=\(wasEnabled), framesSent=\(previewFrameCount)")

        if let output = previewVideoOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
            NSLog("[VideoRecorder] Preview delegate cleared")
        }

        if let session = previewSession {
            // Stop on a background queue to avoid blocking the main thread
            DispatchQueue.global(qos: .userInitiated).async {
                if session.isRunning {
                    session.stopRunning()
                    NSLog("[VideoRecorder] Preview session stopped")
                } else {
                    NSLog("[VideoRecorder] Preview session was already stopped")
                }
            }
        }

        previewVideoOutput = nil
        previewQueue = nil
        previewSession = nil
        lastPreviewSentAt = 0
        // NOTE: We deliberately do NOT clear previewCallbackId here.
        // It is cleared only in previewStop so that late frames don't kill the session.
    }

    //  JPEG

    private func jpegDataFromSampleBuffer(_ sampleBuffer: CMSampleBuffer, quality: CGFloat = 0.85) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            NSLog("[VideoRecorder] jpegData: no pixel buffer")
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        if ciContext == nil {
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
            NSLog("[VideoRecorder] Created new CIContext")
        }
        guard let context = ciContext,
              let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            NSLog("[VideoRecorder] jpegData: failed to create CGImage")
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    //  Background task

    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VideoRecorder") { [weak self] in
            guard let self = self else { return }
            NSLog("[VideoRecorder] Background task expired")
               self.stopRecording()
            self.endBackgroundTask()
        }
        NSLog("[VideoRecorder] Background task started: \(backgroundTask.rawValue)")
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
            NSLog("[VideoRecorder] Background task ended")
        }
    }

    private func dispatchFinalUrl(_ finalUrl: String) {
        NSLog("[VideoRecorder] dispatchFinalUrl: \(finalUrl)")
        let js = """
        document.dispatchEvent(new CustomEvent('VideoRecorderFinished', {
            detail: { file: '\(finalUrl)' }
        }));
        """
        DispatchQueue.main.async {
            self.webViewEngine.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    //  Watermark

    private func loadWatermarkImage() -> UIImage? {
        guard let name = watermarkImage, !name.isEmpty else {
            NSLog("[VideoRecorder] No watermark image name provided")
            return nil
        }

        NSLog("[VideoRecorder] Trying to load watermark: \(name)")

        if let path = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "www") {
            if let img = UIImage(contentsOfFile: path) {
                NSLog("[VideoRecorder] Watermark loaded from www/\(name)")
                return img
            }
        }

        let components = (name as NSString).pathComponents
        let fileName = (components.last ?? name) as NSString
        let dir = components.dropLast().joined(separator: "/")

        let resourceName = fileName.deletingPathExtension
        let ext = fileName.pathExtension.isEmpty ? nil : fileName.pathExtension

        let searchDirs = [
            dir.isEmpty ? "www" : "www/\(dir)",
            "www",
            ""
        ]

        for directory in searchDirs {
            if let path = Bundle.main.path(forResource: resourceName, ofType: ext, inDirectory: directory.isEmpty ? nil : directory) {
                if let img = UIImage(contentsOfFile: path) {
                    NSLog("[VideoRecorder] Watermark loaded from \(directory)/\(resourceName).\(ext ?? "")")
                    return img
                }
            }
        }

        if let path = Bundle.main.path(forResource: resourceName, ofType: ext) {
            if let img = UIImage(contentsOfFile: path) {
                NSLog("[VideoRecorder] Watermark loaded from main bundle")
                return img
            }
        }

        NSLog("[VideoRecorder] FAILED to load watermark image: \(name)")
        return nil
    }

    private func watermarkFrame(videoSize: CGSize, wmSize: CGSize, position: String) -> CGRect {
        let padding: CGFloat = 24
        let isPortrait = videoSize.height > videoSize.width

        // Core Animation coordinate system is often flipped on the Y axis for portrait videos.
        // This helper compensates so the logical positions match user expectation.
        func yValue(forBottomOrigin bottomY: CGFloat) -> CGFloat {
            if isPortrait {
                // Flip
                return videoSize.height - bottomY - wmSize.height
            }
            return bottomY
        }

        switch position.lowercased() {
        case "topleft":
            return CGRect(x: padding,
                          y: yValue(forBottomOrigin: padding),
                          width: wmSize.width,
                          height: wmSize.height)

        case "topright":
            return CGRect(x: videoSize.width - wmSize.width - padding,
                          y: yValue(forBottomOrigin: padding),
                          width: wmSize.width,
                          height: wmSize.height)

        case "bottomleft":
            return CGRect(x: padding,
                          y: yValue(forBottomOrigin: videoSize.height - wmSize.height - padding),
                          width: wmSize.width,
                          height: wmSize.height)

        default: // bottomright
            return CGRect(x: videoSize.width - wmSize.width - padding,
                          y: yValue(forBottomOrigin: videoSize.height - wmSize.height - padding),
                          width: wmSize.width,
                          height: wmSize.height)
        }
    }

    private func applyWatermark(to inputURL: URL, completion: @escaping (URL?) -> Void) {
        guard watermarkEnabled else {
            NSLog("[VideoRecorder] Watermark disabled  skipping")
            completion(inputURL)
            return
        }

        guard let wmUIImage = loadWatermarkImage() else {
            NSLog("[VideoRecorder] Watermark image could not be loaded")
            completion(inputURL)
            return
        }

        NSLog("[VideoRecorder] Applying watermark (\(Int(wmUIImage.size.width))x\(Int(wmUIImage.size.height)))")

        let asset = AVAsset(url: inputURL)
        let mixComposition = AVMutableComposition()

        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compositionVideoTrack = mixComposition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            NSLog("[VideoRecorder] ERROR: could not get video track for watermark")
            completion(nil)
            return
        }

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: videoTrack,
                at: .zero)
        } catch {
            NSLog("[VideoRecorder] Could not insert video track: \(error)")
            completion(nil)
            return
        }

        compositionVideoTrack.preferredTransform = videoTrack.preferredTransform

        // Audio
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = mixComposition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: audioTrack,
                at: .zero)
        }

        // Final render size
        let naturalSize = videoTrack.naturalSize
        let t = videoTrack.preferredTransform

        var renderSize = naturalSize
        if t.a == 0 && t.d == 0 {
            renderSize = CGSize(width: naturalSize.height, height: naturalSize.width)
        }

        // Video composition
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(t, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComp.instructions = [instruction]

        // Layers
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        // Watermark size
        let shorterSide = min(renderSize.width, renderSize.height)
        let wmWidth = shorterSide * 0.28
        let aspect = wmUIImage.size.height / max(wmUIImage.size.width, 1)
        let wmSize = CGSize(width: wmWidth, height: wmWidth * aspect)

        let wmLayer = CALayer()
        wmLayer.contents = wmUIImage.cgImage
        wmLayer.contentsGravity = .resizeAspect
        wmLayer.opacity = 1.0

        // ----- Use the helper function -----
        wmLayer.frame = watermarkFrame(videoSize: renderSize, wmSize: wmSize, position: watermarkPosition)
        parentLayer.addSublayer(wmLayer)

        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VID_WM_\(Int(Date().timeIntervalSince1970)).mov")

        guard let exporter = AVAssetExportSession(
            asset: mixComposition,
            presetName: AVAssetExportPresetHighestQuality) else {
            NSLog("[VideoRecorder] ERROR: could not create export session for watermark")
            completion(nil)
            return
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComp

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed {
                    NSLog("[VideoRecorder] Watermark applied successfully  \(outputURL.lastPathComponent)")
                    completion(outputURL)
                } else {
                    NSLog("[VideoRecorder] Watermark export failed: \(String(describing: exporter.error))")
                    completion(nil)
                }
            }
        }
    }

    private func fetchAndExportAsset(localId: String, attempt: Int) {
        if attempt > 10 {
            NSLog("[VideoRecorder] fetchAndExportAsset gave up after 10 attempts")
            return
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = assets.firstObject else {
            NSLog("[VideoRecorder] fetchAndExportAsset  asset not ready, attempt \(attempt)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.fetchAndExportAsset(localId: localId, attempt: attempt + 1)
            }
            return
        }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            guard let avAsset = avAsset else {
                NSLog("[VideoRecorder] requestAVAsset failed, attempt \(attempt)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.fetchAndExportAsset(localId: localId, attempt: attempt + 1)
                }
                return
            }

            let exportUrl = FileManager.default.temporaryDirectory.appendingPathComponent("VID_EXPORT_\(Int(Date().timeIntervalSince1970)).mov")

            guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
                NSLog("[VideoRecorder] Could not create export session for Photos asset")
                return
            }
            exportSession.outputURL = exportUrl
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true

            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    NSLog("[VideoRecorder] Photos export completed")
                    self.dispatchFinalUrl("file://\(exportUrl.path)")
                } else {
                    NSLog("[VideoRecorder] Photos export failed: \(String(describing: exportSession.error))")
                }
            }
        }
    }

    private func saveToPhotosAndExport(url: URL) {
        NSLog("[VideoRecorder] Saving to Photos: \(url.lastPathComponent)")
        var savedLocalId: String?

        PHPhotoLibrary.shared().performChanges({
            if let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url),
               let placeholder = request.placeholderForCreatedAsset {
                savedLocalId = placeholder.localIdentifier
            }
        }) { success, error in
            if let error = error {
                NSLog("[VideoRecorder] Error saving to Photos: \(error)")
            }
            try? FileManager.default.removeItem(at: url)

            guard success, let localId = savedLocalId else {
                NSLog("[VideoRecorder] saveToPhotos failed or no localId")
                return
            }
            NSLog("[VideoRecorder] Saved to Photos, localId=\(localId)")
            self.fetchAndExportAsset(localId: localId, attempt: 1)
        }
    }
}

//  Recording delegate

extension VideoRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {

        NSLog("[VideoRecorder] didFinishRecording  error=\(String(describing: error)), file=\(outputFileURL.lastPathComponent)")

        // Stop the session on the recording queue
        recordingQueue.async { [weak self] in
            guard let self = self else { return }
            if let session = self.captureSession, session.isRunning {
                session.stopRunning()
            }
            self.captureSession = nil
            self.movieOutput = nil
        }

        try? AVAudioSession.sharedInstance().setActive(false)
        endBackgroundTask()

        applyWatermark(to: outputFileURL) { [weak self] processedURL in
            guard let self = self else { return }
            let finalURL = processedURL ?? outputFileURL

            if self.saveToGallery {
                self.saveToPhotosAndExport(url: finalURL)
            } else {
                self.dispatchFinalUrl("file://\(finalURL.path)")
            }
        }
    }
}

//  Preview delegate

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard previewEnabled else { return }
        guard let cbId = previewCallbackId else {
            // Only log occasionally so we don't spam
            if previewFrameCount % 30 == 0 {
                NSLog("[VideoRecorder] captureOutput: previewEnabled=true but previewCallbackId is nil (frame \(previewFrameCount))")
            }
            return
        }

        let now = Date().timeIntervalSince1970
        let minInterval = previewTargetFps > 0 ? 1.0 / Double(previewTargetFps) : 0.0
        if minInterval > 0 && now - lastPreviewSentAt < minInterval { return }
        lastPreviewSentAt = now

        guard let jpeg = jpegDataFromSampleBuffer(sampleBuffer, quality: previewJpegQuality) else {
            if previewFrameCount % 30 == 0 {
                NSLog("[VideoRecorder] captureOutput: JPEG conversion failed (frame \(previewFrameCount))")
            }
            return
        }

        previewFrameCount += 1

        // Log every 15th frame so we can see progress without flooding the console
        if previewFrameCount == 1 || previewFrameCount % 15 == 0 {
            NSLog("[VideoRecorder] Sending preview frame #\(previewFrameCount) (size=\(jpeg.count) bytes)")
        }

        let dataUri = "data:image/jpeg;base64," + jpeg.base64EncodedString()

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.previewEnabled, self.previewCallbackId == cbId else {
                NSLog("[VideoRecorder] Dropped frame  state changed before main-queue send")
                return
            }

            let result = CDVPluginResult(status: .ok, messageAs: dataUri)
            result.setKeepCallbackAs(true)
            self.commandDelegate.send(result, callbackId: cbId)
        }
    }
}