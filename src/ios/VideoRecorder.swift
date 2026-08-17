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

        NSLog("[VideoRecorder] start called, maxLength=\(maxLengthSec), requested=\(videoWidth)x\(videoHeight), camera=\(cameraPosition == .front ? "front" : "back")")

        startBackgroundTask()
        setupSession()
        startRecording()

        let result = CDVPluginResult(status: .ok)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    @objc(stop:)
    func stop(command: CDVInvokedUrlCommand) {
        self.callbackId = command.callbackId
        stopRecording()
    }

    //  Preview actions

    @objc(preview:)
    func preview(command: CDVInvokedUrlCommand) {
        let arg = command.arguments.first

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
            previewJpegQuality = CGFloat(quality) / 100.0
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

        previewCallbackId = command.callbackId

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.previewEnabled {
                let result = CDVPluginResult(status: .ok, messageAs: "preview_already_started")
                result.setKeepCallbackAs(true)
                if let cb = self.previewCallbackId {
                    self.commandDelegate.send(result, callbackId: cb)
                }
                return
            }

            self.previewEnabled = true
            self.lastPreviewSentAt = 0

            let startResult = CDVPluginResult(status: .ok, messageAs: "preview_started")
            startResult.setKeepCallbackAs(true)
            if let cb = self.previewCallbackId {
                self.commandDelegate.send(startResult, callbackId: cb)
            }

            self.setupPreviewSession()
        }
    }

    @objc(previewStop:)
    func previewStop(command: CDVInvokedUrlCommand) {
        stopPreviewSession()

        let stopResult = CDVPluginResult(status: .ok, messageAs: "preview_stopped")
        stopResult.setKeepCallbackAs(false)

        if let cb = command.callbackId {
            commandDelegate.send(stopResult, callbackId: cb)
        } else if let cb = previewCallbackId {
            commandDelegate.send(stopResult, callbackId: cb)
        }
        previewCallbackId = nil
    }

    //  Recording

    private func setupSession() {
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
        guard let movieOutput = movieOutput,
              let session = captureSession else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileUrl = docs.appendingPathComponent("VID_\(formatter.string(from: Date())).mov")
        outputUrl = fileUrl

        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        if let connection = movieOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        if maxLengthSec > 0 {
            movieOutput.maxRecordedDuration = CMTime(seconds: Double(maxLengthSec), preferredTimescale: 600)

            stopTimer = Timer(timeInterval: Double(maxLengthSec) + 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.stopRecording()
            }
            if let t = stopTimer {
                RunLoop.main.add(t, forMode: .common)
            }
        }

        session.startRunning()
        movieOutput.startRecording(to: fileUrl, recordingDelegate: self)
    }

    private func stopRecording() {
        if let timer = stopTimer {
            timer.invalidate()
        }
        stopTimer = nil

        guard let movieOutput = movieOutput else { return }
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
    }

    //  Preview session

    private func setupPreviewSession() {
        stopPreviewSession()

        let session = AVCaptureSession()
        session.beginConfiguration()

        let requestedLong = max(previewWidth, previewHeight)
        let targetLong = min(requestedLong, previewMaxLongSide)

        if targetLong >= 1920 && session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if targetLong >= 1280 && session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            session.sessionPreset = .high
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: previewCameraPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        let queue = DispatchQueue(label: "VideoRecorderPreviewQueue", qos: .userInitiated)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: queue)
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            connection.isVideoMirrored = (previewCameraPosition == .front && connection.isVideoMirroringSupported)
        }

        session.commitConfiguration()

        previewSession = session
        previewVideoOutput = videoOutput
        previewQueue = queue

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopPreviewSession() {
        previewEnabled = false

        if let session = previewSession {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }

        if let output = previewVideoOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
        }
        previewVideoOutput = nil
        previewQueue = nil
        previewSession = nil
        lastPreviewSentAt = 0
    }

    //  JPEG

    private func jpegDataFromSampleBuffer(_ sampleBuffer: CMSampleBuffer, quality: CGFloat = 0.85) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        if ciContext == nil {
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
        guard let context = ciContext,
              let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    //  Background task

    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VideoRecorder") { [weak self] in
            // FIXED
            guard let self = self else { return }
            self.endBackgroundTask()
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
                    NSLog("[VideoRecorder] Watermark applied successfully ? \(outputURL.lastPathComponent)")
                    completion(outputURL)
                } else {
                    NSLog("[VideoRecorder] Watermark export failed: \(String(describing: exporter.error))")
                    completion(nil)
                }
            }
        }
    }

    private func fetchAndExportAsset(localId: String, attempt: Int) {
        if attempt > 10 { return }

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
            guard let avAsset = avAsset else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.fetchAndExportAsset(localId: localId, attempt: attempt + 1)
                }
                return
            }

            let exportUrl = FileManager.default.temporaryDirectory.appendingPathComponent("VID_EXPORT_\(Int(Date().timeIntervalSince1970)).mov")

            guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else { return }
            exportSession.outputURL = exportUrl
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true

            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    self.dispatchFinalUrl("file://\(exportUrl.path)")
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

            guard success, let localId = savedLocalId else { return }
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

        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        captureSession = nil
        movieOutput = nil

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

        let now = Date().timeIntervalSince1970
        let minInterval = previewTargetFps > 0 ? 1.0 / Double(previewTargetFps) : 0.0
        if minInterval > 0 && now - lastPreviewSentAt < minInterval { return }
        lastPreviewSentAt = now

        guard let cbId = previewCallbackId else {
            if previewEnabled {
                DispatchQueue.main.async { [weak self] in
                    // FIXED
                    guard let self = self else { return }
                    self.previewEnabled = false
                    self.stopPreviewSession()
                }
            }
            return
        }

        guard let jpeg = jpegDataFromSampleBuffer(sampleBuffer, quality: previewJpegQuality) else { return }

        let dataUri = "data:image/jpeg;base64," + jpeg.base64EncodedString()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let result = CDVPluginResult(status: .ok, messageAs: dataUri)
            result.setKeepCallbackAs(true)
            self.commandDelegate.send(result, callbackId: cbId)
        }
    }
}