import Foundation
import AVFoundation
import Photos
import Cordova
import UIKit

@objc(VideoRecorder)
class VideoRecorder: CDVPlugin {

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

    // Watermark options
    var watermarkEnabled: Bool = false
    var watermarkImage: String?
    var watermarkPosition: String = "bottomright"

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
               let w = Int(parts[0]),
               let h = Int(parts[1]),
               w > 0, h > 0 {
                videoWidth = w
                videoHeight = h
            }
        }

        if let cam = options["camera"] as? String {
            cameraPosition = cam.lowercased() == "front" ? .front : .back
        }

        // Watermark options: watermark: { image, position }
        if let wm = options["watermark"] as? [String: Any] {
            watermarkEnabled = true
            watermarkImage = wm["image"] as? String
            watermarkPosition = (wm["position"] as? String) ?? "bottomright"
        } else {
            watermarkEnabled = false
            watermarkImage = nil
        }

        NSLog("[VideoRecorder] start called, maxLength=\(maxLengthSec), requested=\(videoWidth)x\(videoHeight), camera=\(cameraPosition == .front ? "front" : "back"), saveToGallery=\(saveToGallery), watermarkEnabled=\(watermarkEnabled)")

        startBackgroundTask()
        setupSession()
        startRecording()

        let result = CDVPluginResult(status: .ok)
        if let cb = command.callbackId {
            self.commandDelegate.send(result, callbackId: cb)
        } else {
            NSLog("[VideoRecorder] start: no callbackId to send result")
        }

    }

    @objc(stop:)
    func stop(command: CDVInvokedUrlCommand) {
        self.callbackId = command.callbackId
        NSLog("[VideoRecorder] stop called from JS")
        stopRecording()
    }

    private func setupSession() {
        let session = AVCaptureSession()
        captureSession = session
        session.beginConfiguration()

        // Use requested resolution only to choose preset (quality), not orientation
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
            NSLog("[VideoRecorder] Failed to create video input")
            session.commitConfiguration()
            return
        }
        session.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            self.movieOutput = movieOutput
        }

        session.commitConfiguration()
    }

    private func startRecording() {
        guard let movieOutput = self.movieOutput,
              let session = self.captureSession else {
            NSLog("[VideoRecorder] startRecording aborted: session or output nil")
            return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "VID_\(formatter.string(from: Date())).mov"
        let fileUrl = docs.appendingPathComponent(filename)
        self.outputUrl = fileUrl

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers])
        try? audioSession.setActive(true)

        if let connection = movieOutput.connection(with: .video) {
            // Let AVFoundation handle orientation via preferredTransform.
            connection.videoOrientation = .portrait
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        if maxLengthSec > 0 {
            movieOutput.maxRecordedDuration = CMTime(seconds: Double(maxLengthSec), preferredTimescale: 600)

            stopTimer = Timer(timeInterval: Double(maxLengthSec) + 0.5,
                              repeats: false) { [weak self] _ in
                self?.stopRecording()
            }

            if let stopTimer = stopTimer {
                RunLoop.main.add(stopTimer, forMode: .common)
            }
        }

        session.startRunning()
        movieOutput.startRecording(to: fileUrl, recordingDelegate: self)
    }

    private func stopRecording() {
        stopTimer?.invalidate()
        stopTimer = nil

        guard let movieOutput = self.movieOutput else { return }

        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
    }

    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VideoRecorder") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func dispatchFinalUrl(_ finalUrl: String) {
        let js = """
        document.dispatchEvent(new CustomEvent('VideoRecorderFinished', {
            detail: { file: '\(finalUrl)' }
        }));
        """

        DispatchQueue.main.async {
            self.webViewEngine.evaluateJavaScript(js)
        }
    }

    // MARK: - Watermark helpers

    private func loadWatermarkImage() -> UIImage? {
        guard let name = watermarkImage, !name.isEmpty else { return nil }

        let components = (name as NSString).pathComponents
        let fileName = (components.last ?? name) as NSString
        let dir = components.dropLast().joined(separator: "/")

        let resourceName = fileName.deletingPathExtension
        let ext = fileName.pathExtension

        if let path = Bundle.main.path(forResource: resourceName,
                                       ofType: ext.isEmpty ? nil : ext,
                                       inDirectory: dir.isEmpty ? "www" : "www/\(dir)") {
            return UIImage(contentsOfFile: path)
        }

        if let path = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "www") {
            return UIImage(contentsOfFile: path)
        }

        return nil
    }

    private func watermarkFrame(videoSize: CGSize, wmSize: CGSize, position: String) -> CGRect {
        let padding: CGFloat = 10
        let w = wmSize.width
        let h = wmSize.height

        switch position.lowercased() {
        case "topleft":
            return CGRect(x: padding,
                          y: padding,
                          width: w,
                          height: h)

        case "topright":
            return CGRect(x: videoSize.width - w - padding,
                          y: padding,
                          width: w,
                          height: h)

        case "bottomleft":
            return CGRect(x: padding,
                          y: videoSize.height - h - padding,
                          width: w,
                          height: h)

        default: // bottomright
            return CGRect(x: videoSize.width - w - padding,
                          y: videoSize.height - h - padding,
                          width: w,
                          height: h)
        }
    }



    /// Apply watermark if enabled.
    private func applyWatermark(to inputURL: URL, completion: @escaping (URL?) -> Void) {
        guard watermarkEnabled, let wmImage = loadWatermarkImage() else {
            completion(inputURL)
            return
        }

        let asset = AVAsset(url: inputURL)
        let mixComposition = AVMutableComposition()

        guard
            let videoTrack = asset.tracks(withMediaType: .video).first,
            let compositionVideoTrack = mixComposition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            NSLog("[VideoRecorder] Failed to create composition video track")
            completion(nil)
            return
        }

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: videoTrack,
                at: .zero
            )
        } catch {
            NSLog("[VideoRecorder] Failed to insert video track: \(error)")
            completion(nil)
            return
        }

        compositionVideoTrack.preferredTransform = videoTrack.preferredTransform

        // Copy audio if present
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = mixComposition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: audioTrack,
                at: .zero
            )
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let naturalSize = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform

        // Compute final displayed size after applying transform
        let displayWidth = abs(naturalSize.width * transform.a) + abs(naturalSize.height * transform.c)
        let displayHeight = abs(naturalSize.width * transform.b) + abs(naturalSize.height * transform.d)
        let finalSize = CGSize(width: displayWidth, height: displayHeight)

        videoComposition.renderSize = finalSize

        NSLog("[VideoRecorder] applyWatermark: natural=\(naturalSize), final=\(finalSize), position=\(watermarkPosition)")

        // Video composition instruction
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Layer setup
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: finalSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        // Watermark layer
        let wmLayer = CALayer()
        wmLayer.contents = wmImage.cgImage
        wmLayer.contentsGravity = .resizeAspect  // good for scaling

        // Calculate watermark size (20% of video width)
        let targetWidth = finalSize.width * 0.20
        let aspectRatio = wmImage.size.height / wmImage.size.width
        let targetHeight = targetWidth * aspectRatio
        let wmSize = CGSize(width: targetWidth, height: targetHeight)

        // Get initial frame using your existing logic
        var wmFrame = watermarkFrame(
            videoSize: finalSize,
            wmSize: wmSize,
            position: watermarkPosition
        )

        // === CRITICAL FIX: Handle portrait orientation Y-flip ===
        let isPortrait = finalSize.height > finalSize.width
        
        if isPortrait {
            // In portrait mode with CoreAnimationTool, the Y axis is often inverted
            wmFrame.origin.y = finalSize.height - wmFrame.maxY
        }

        wmLayer.frame = wmFrame
        wmLayer.opacity = 1.0

        parentLayer.addSublayer(wmLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // Export
        let tempDir = FileManager.default.temporaryDirectory
        let outName = "VID_WM_\(Int(Date().timeIntervalSince1970)).mov"
        let outURL = tempDir.appendingPathComponent(outName)

        guard let exporter = AVAssetExportSession(asset: mixComposition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            NSLog("[VideoRecorder] Failed to create AVAssetExportSession")
            completion(nil)
            return
        }

        exporter.outputURL = outURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition

        exporter.exportAsynchronously {
            switch exporter.status {
            case .completed:
                NSLog("[VideoRecorder] Watermark applied successfully")
                completion(outURL)
            case .failed:
                NSLog("[VideoRecorder] Watermark export failed: \(exporter.error?.localizedDescription ?? "unknown")")
                completion(nil)
            default:
                NSLog("[VideoRecorder] Watermark export status: \(exporter.status.rawValue)")
                completion(nil)
            }
        }
    }

    private func saveToPhotosAndExport(url: URL) {
        NSLog("[VideoRecorder] saveToPhotosAndExport called for \(url.path)")

        var savedLocalId: String?

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            savedLocalId = request?.placeholderForCreatedAsset?.localIdentifier
        }) { success, error in

            if let error = error {
                NSLog("[VideoRecorder] Error saving to Photos: \(String(describing: error))")
            }

            try? FileManager.default.removeItem(at: url)

            guard success, let localId = savedLocalId else {
                NSLog("[VideoRecorder] Save failed or missing localIdentifier")
                return
            }

            self.fetchAndExportAsset(localId: localId, attempt: 1)
        }
    }

    private func fetchAndExportAsset(localId: String, attempt: Int) {
        if attempt > 10 {
            NSLog("[VideoRecorder] Asset not ready after 10 attempts")
            return
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)

        guard let asset = assets.firstObject else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.fetchAndExportAsset(localId: localId, attempt: attempt + 1)
            }
            return
        }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in

            if avAsset == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.fetchAndExportAsset(localId: localId, attempt: attempt + 1)
                }
                return
            }

            guard let avAsset = avAsset else { return }

            let tempDir = FileManager.default.temporaryDirectory
            let exportFilename = "VID_EXPORT_\(Int(Date().timeIntervalSince1970)).mov"
            let exportUrl = tempDir.appendingPathComponent(exportFilename)

            guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
                NSLog("[VideoRecorder] Failed to create AVAssetExportSession")
                return
            }

            exportSession.outputURL = exportUrl
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true

            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    let finalUrl = "file://\(exportUrl.path)"
                    self.dispatchFinalUrl(finalUrl)

                case .failed, .cancelled:
                    let errDesc = exportSession.error?.localizedDescription ?? "unknown"
                    NSLog("[VideoRecorder] Export failed/cancelled: \(errDesc)")

                default:
                    break
                }
            }
        }
    }
  
    private var previewSession: AVCaptureSession?
    private var previewVideoOutput: AVCaptureVideoDataOutput?
    private var previewQueue: DispatchQueue?
    private var previewCallbackId: String?
    private var previewEnabled: Bool = false
    private var previewTargetFps: Int = 10
    private var lastPreviewSentAt: TimeInterval = 0
    private var ciContext: CIContext? = CIContext()

    @objc(previewStart:)
    func previewStart(command: CDVInvokedUrlCommand) {
        // Accept same options as Android: { fps: 10, camera: "front"|"back", resolution: "1080x1920" }
        let options = command.arguments.first as? [String: Any] ?? [:]

        // Parse fps
        if let fps = options["fps"] as? Int, fps > 0 { previewTargetFps = fps }

        // Parse camera
        if let cam = options["camera"] as? String {
            cameraPosition = cam.lowercased() == "front" ? .front : .back
        }

        // Parse resolution string (same parsing logic as Android)
        if let res = options["resolution"] as? String {
            let parts = res.lowercased().split(separator: "x")
            if parts.count == 2,
            let w = Int(parts[0]),
            let h = Int(parts[1]),
            w > 0, h > 0 {
                videoWidth = w
                videoHeight = h
            }
        }

        // Save callback id
        self.previewCallbackId = command.callbackId

        // Ensure previewEnabled is set on main thread before starting session to avoid races
        DispatchQueue.main.async {
            NSLog("[VideoRecorder] previewStart called on instance \(Unmanaged.passUnretained(self).toOpaque()) callbackId=\(String(describing: self.previewCallbackId)) camera=\(self.cameraPosition == .front ? "front" : "back") requested=\(self.videoWidth)x\(self.videoHeight) fps=\(self.previewTargetFps)")

            // If already running, acknowledge
            if self.previewEnabled {
                let result = CDVPluginResult(status: .ok, messageAs: "preview_already_started")
                result.setKeepCallbackAs(true)
                if let cb = self.previewCallbackId {
                    self.commandDelegate.send(result, callbackId: cb)
                } else {
                    NSLog("[VideoRecorder] previewStart: preview already started but no previewCallbackId available")
                }
                return
            }

            self.previewEnabled = true
            self.lastPreviewSentAt = 0

            let startResult = CDVPluginResult(status: .ok, messageAs: "preview_started")
            startResult.setKeepCallbackAs(true)
            if let cb = self.previewCallbackId {
                self.commandDelegate.send(startResult, callbackId: cb)
            } else {
                NSLog("[VideoRecorder] previewStart: no callbackId to send startResult")
            }

            // Start preview session (will choose a preset based on requested resolution)
            self.setupPreviewSession()
        }
    }

    @objc(previewStop:)
    func previewStop(command: CDVInvokedUrlCommand) {
        // Stop preview and notify JS once
        stopPreviewSession()
        let stopResult = CDVPluginResult(status: .ok, messageAs: "preview_stopped")
        stopResult.setKeepCallbackAs(false)

        if let cb = command.callbackId {
            self.commandDelegate.send(stopResult, callbackId: cb)
        } else if let cb = previewCallbackId {
            self.commandDelegate.send(stopResult, callbackId: cb)
        } else {
            NSLog("[VideoRecorder] previewStop: no callbackId to send stopResult")
        }
        previewCallbackId = nil

    }
    
    /**
    * Cordova action dispatcher for "preview".
    * Accepts:
    *  - An options dictionary (same shape as Android): { camera: "front"|"back", resolution: "1080x1920", fps: 10 }
    *  - A boolean: true -> start, false -> stop (backwards compatible)
    *  - A string: "start" / "stop"
    *  - No arg: toggles preview
    */
    @objc(preview:)
    func preview(command: CDVInvokedUrlCommand) {
        let arg = command.arguments.first

        // If first arg is a dictionary, treat it as options and start preview with those options
        if let opts = arg as? [String: Any] {
            // Build a new CDVInvokedUrlCommand-like wrapper: reuse the same command but with options as first arg
            // previewStart expects a CDVInvokedUrlCommand; we can forward the same command (it already contains the options)
            self.previewStart(command: command)
            return
        }

        // If boolean true/false
        if let boolArg = arg as? Bool {
            if boolArg {
                self.previewStart(command: command)
            } else {
                self.previewStop(command: command)
            }
            return
        }

        // If string "start"/"stop"
        if let strArg = arg as? String {
            let lower = strArg.lowercased()
            if lower == "start" {
                self.previewStart(command: command)
                return
            } else if lower == "stop" {
                self.previewStop(command: command)
                return
            }
        }

        // If array with single element that is string or bool, handle it (some JS calls pass arrays)
        if let arr = arg as? [Any], arr.count > 0 {
            let first = arr[0]
            if let boolFirst = first as? Bool {
                if boolFirst { self.previewStart(command: command) } else { self.previewStop(command: command) }
                return
            }
            if let strFirst = first as? String {
                let lower = strFirst.lowercased()
                if lower == "start" { self.previewStart(command: command); return }
                if lower == "stop"  { self.previewStop(command: command); return }
            }
            if let optsFirst = first as? [String: Any] {
                // If the first element is an options object, create a new command with that object as the first argument.
                // Cordova's CDVInvokedUrlCommand is a class; we can forward the original command because it already contains the args array.
                self.previewStart(command: command)
                return
            }
        }

        // Fallback: toggle preview
        if previewEnabled {
            self.previewStop(command: command)
        } else {
            self.previewStart(command: command)
        }
    }


    private func setupPreviewSession() {
        // Tear down any existing preview session first
        stopPreviewSession()

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Choose session preset based on requested resolution (mirror Android parseResolution logic)
        // We treat requested width/height as orientation-agnostic: prefer a preset that matches rotated or same orientation.
        let reqW = max(videoWidth, videoHeight)
        let reqH = min(videoWidth, videoHeight)

        // Prefer 1080p if requested >= 1920x1080 (or rotated)
        if (reqW >= 1920 && reqH >= 1080) && session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if (reqW >= 1280 && reqH >= 720) && session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            // Fallback to whatever is available
            session.sessionPreset = .high
        }

        // Select camera device (respect cameraPosition)
        var videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)
        if videoDevice == nil {
            videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }

        guard let vDevice = videoDevice,
            let videoInput = try? AVCaptureDeviceInput(device: vDevice),
            session.canAddInput(videoInput) else {
            NSLog("[VideoRecorder] setupPreviewSession: failed to create video input for cameraPosition=\(cameraPosition == .front ? "front" : "back")")
            session.commitConfiguration()
            return
        }
        session.addInput(videoInput)

        // Create video data output (BGRA for CI conversion)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        // Use a dedicated queue with userInitiated QoS for better throughput
        let queue = DispatchQueue(label: "VideoRecorderPreviewQueue", qos: .userInitiated)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            NSLog("[VideoRecorder] setupPreviewSession: setSampleBufferDelegate on queue \(queue.label) for instance \(Unmanaged.passUnretained(self).toOpaque()) callbackId=\(String(describing: previewCallbackId)) preset=\(session.sessionPreset.rawValue)")
        } else {
            NSLog("[VideoRecorder] setupPreviewSession: cannot add video data output")
        }

        // Configure connection orientation and mirroring
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            if cameraPosition == .front, connection.isVideoMirroringSupported {
                // Mirror preview for selfie UX (Android preview mirrors front camera)
                connection.isVideoMirrored = true
            } else {
                connection.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        // Save references and start
        self.previewSession = session
        self.previewVideoOutput = videoOutput
        self.previewQueue = queue

        // Start session on background thread and log lifecycle
        DispatchQueue.global(qos: .userInitiated).async {
            NSLog("[VideoRecorder] setupPreviewSession: starting session on background thread for instance \(Unmanaged.passUnretained(self).toOpaque()) callbackId=\(String(describing: self.previewCallbackId)) preset=\(session.sessionPreset.rawValue)")
            session.startRunning()
            NSLog("[VideoRecorder] setupPreviewSession: session.startRunning returned for instance \(Unmanaged.passUnretained(self).toOpaque()) callbackId=\(String(describing: self.previewCallbackId))")
        }
    }

    private func stopPreviewSession() {
        previewEnabled = false
        // Stop session on background thread
        if let session = previewSession {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }

        // Clear delegates and references
        if let videoOutput = previewVideoOutput {
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
        }
        previewVideoOutput = nil
        previewQueue = nil
        previewSession = nil
        lastPreviewSentAt = 0
        // Do not clear previewCallbackId here if you want JS to receive final "preview_stopped" from previewStop()
    }

    // Helper: convert sampleBuffer -> JPEG Data (returns nil on failure)
    private func jpegDataFromSampleBuffer(_ sampleBuffer: CMSampleBuffer, quality: CGFloat = 0.6) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Use CIContext to create CGImage then UIImage
        if ciContext == nil { ciContext = CIContext() }
        guard let cgImage = ciContext?.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }

}

extension VideoRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {

        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        captureSession = nil
        movieOutput = nil

        try? AVAudioSession.sharedInstance().setActive(false)
        endBackgroundTask()

        applyWatermark(to: outputFileURL) { processedURL in
            let finalURL = processedURL ?? outputFileURL

            if self.saveToGallery {
                self.saveToPhotosAndExport(url: finalURL)
            } else {
                self.dispatchFinalUrl("file://\(finalURL.path)")
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (preview forwarding)
extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    // Replace your existing captureOutput implementation with this block
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Log entry and instance pointer
        NSLog("[VideoRecorder] captureOutput called on instance \(Unmanaged.passUnretained(self).toOpaque()) previewEnabled=\(previewEnabled) previewCallbackId=\(String(describing: previewCallbackId))")

        // Throttle by previewTargetFps
        let now = Date().timeIntervalSince1970
        let minInterval = previewTargetFps > 0 ? (1.0 / Double(previewTargetFps)) : 0.0
        if minInterval > 0 && now - lastPreviewSentAt < minInterval {
            return
        }
        lastPreviewSentAt = now

        // Primary gate: only forward if we have a callback id (this avoids instance boolean races)
        guard let cbId = previewCallbackId else {
            // If previewEnabled is true but callback missing, log and stop preview on main thread
            if previewEnabled {
                NSLog("[VideoRecorder] captureOutput: previewEnabled true but no previewCallbackId — stopping preview on instance \(Unmanaged.passUnretained(self).toOpaque())")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.previewEnabled = false
                    self.stopPreviewSession()
                }
            } else {
                // Normal: preview not requested on this instance
                NSLog("[VideoRecorder] captureOutput: previewCallbackId nil, dropping frame on instance \(Unmanaged.passUnretained(self).toOpaque())")
            }
            return
        }

        // Convert to JPEG bytes (defensive)
        guard let jpeg = jpegDataFromSampleBuffer(sampleBuffer, quality: 0.6) else {
            NSLog("[VideoRecorder] captureOutput: jpegDataFromSampleBuffer returned nil on instance \(Unmanaged.passUnretained(self).toOpaque())")
            return
        }

        // Build data URI
        let b64 = jpeg.base64EncodedString(options: [])
        let dataUri = "data:image/jpeg;base64,\(b64)"

        // Log summary and send on main thread
        NSLog("[VideoRecorder] captureOutput: sending frame len=\(jpeg.count) to callbackId=\(cbId) on instance \(Unmanaged.passUnretained(self).toOpaque())")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let pluginResult = CDVPluginResult(status: .ok, messageAs: dataUri)
            pluginResult.setKeepCallbackAs(true)
            self.commandDelegate.send(pluginResult, callbackId: cbId)
        }
    }


}

