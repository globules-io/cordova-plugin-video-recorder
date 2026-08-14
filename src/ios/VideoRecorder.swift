import Foundation
import AVFoundation
import Photos
import Cordova
import UIKit

@objc(VideoRecorder)
class VideoRecorder: CDVPlugin {

    // Recording state
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

    // Preview state 
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

    // Safety cap for base64 frames (long side)
    private let previewMaxLongSide = 1280

    // Cordova actions

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
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    @objc(stop:)
    func stop(command: CDVInvokedUrlCommand) {
        self.callbackId = command.callbackId
        NSLog("[VideoRecorder] stop called from JS")
        stopRecording()
    }

    // Preview actions

    @objc(preview:)
    func preview(command: CDVInvokedUrlCommand) {
        let arg = command.arguments.first

        if let _ = arg as? [String: Any] {
            previewStart(command: command)
            return
        }

        if let boolArg = arg as? Bool {
            if boolArg {
                previewStart(command: command)
            } else {
                previewStop(command: command)
            }
            return
        }

        if let strArg = arg as? String {
            let lower = strArg.lowercased()
            if lower == "start" {
                previewStart(command: command)
                return
            } else if lower == "stop" {
                previewStop(command: command)
                return
            }
        }

        if let arr = arg as? [Any], !arr.isEmpty {
            let first = arr[0]
            if let boolFirst = first as? Bool {
                if boolFirst { previewStart(command: command) } else { previewStop(command: command) }
                return
            }
            if let strFirst = first as? String {
                let lower = strFirst.lowercased()
                if lower == "start" { previewStart(command: command); return }
                if lower == "stop"  { previewStop(command: command); return }
            }
            if first is [String: Any] {
                previewStart(command: command)
                return
            }
        }

        // Fallback toggle
        if previewEnabled {
            previewStop(command: command)
        } else {
            previewStart(command: command)
        }
    }

    @objc(previewStart:)
    func previewStart(command: CDVInvokedUrlCommand) {
        let options = command.arguments.first as? [String: Any] ?? [:]

        if let fps = options["fps"] as? Int, fps > 0 {
            previewTargetFps = fps
        }

        if let quality = options["quality"] as? Int{
            previewJpegQuality = CGFloat(quality) / 100
        }

        if let cam = options["camera"] as? String {
            previewCameraPosition = cam.lowercased() == "front" ? .front : .back
        }

        if let res = options["resolution"] as? String {
            let parts = res.lowercased().split(separator: "x")
            if parts.count == 2,
               let w = Int(parts[0]),
               let h = Int(parts[1]),
               w > 0, h > 0 {
                previewWidth = w
                previewHeight = h
            }
        }

        self.previewCallbackId = command.callbackId

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            NSLog("[VideoRecorder] previewStart camera=\(self.previewCameraPosition == .front ? "front" : "back") requested=\(self.previewWidth)x\(self.previewHeight) fps=\(self.previewTargetFps)")

            if self.previewEnabled {
                let result = CDVPluginResult(status: .ok, messageAs: "preview_already_started")
                result?.setKeepCallbackAs(true)
                self.commandDelegate.send(result, callbackId: self.previewCallbackId)
                return
            }

            self.previewEnabled = true
            self.lastPreviewSentAt = 0

            let startResult = CDVPluginResult(status: .ok, messageAs: "preview_started")
            startResult?.setKeepCallbackAs(true)
            self.commandDelegate.send(startResult, callbackId: self.previewCallbackId)

            self.setupPreviewSession()
        }
    }

    @objc(previewStop:)
    func previewStop(command: CDVInvokedUrlCommand) {
        stopPreviewSession()

        let stopResult = CDVPluginResult(status: .ok, messageAs: "preview_stopped")
        stopResult?.setKeepCallbackAs(false)

        if let cb = command.callbackId {
            commandDelegate.send(stopResult, callbackId: cb)
        } else if let cb = previewCallbackId {
            commandDelegate.send(stopResult, callbackId: cb)
        }

        previewCallbackId = nil
    }

    // Recording session

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
            connection.videoOrientation = .portrait
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        if maxLengthSec > 0 {
            movieOutput.maxRecordedDuration = CMTime(seconds: Double(maxLengthSec), preferredTimescale: 600)

            stopTimer = Timer(timeInterval: Double(maxLengthSec) + 0.5, repeats: false) { [weak self] _ in
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

    // Preview session (independent)

    private func setupPreviewSession() {
        stopPreviewSession()

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Cap long side for base64 safety
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
            NSLog("[VideoRecorder] setupPreviewSession: failed to create video input")
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
            if previewCameraPosition == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            } else {
                connection.isVideoMirrored = false
            }
        }

        session.commitConfiguration()

        self.previewSession = session
        self.previewVideoOutput = videoOutput
        self.previewQueue = queue

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            NSLog("[VideoRecorder] preview session started (preset=\(session.sessionPreset.rawValue))")
        }
    }

    private func stopPreviewSession() {
        previewEnabled = false

        if let session = previewSession {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }

        previewVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
        previewVideoOutput = nil
        previewQueue = nil
        previewSession = nil
        lastPreviewSentAt = 0
    }

    // JPEG conversion

    private func jpegDataFromSampleBuffer(_ sampleBuffer: CMSampleBuffer, quality: CGFloat = 0.85) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        if ciContext == nil {
            ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
        guard let cgImage = ciContext?.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }

    // Background task helpers

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
            self.webViewEngine.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // Watermark helpers

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
            return CGRect(x: padding, y: padding, width: w, height: h)
        case "topright":
            return CGRect(x: videoSize.width - w - padding, y: padding, width: w, height: h)
        case "bottomleft":
            return CGRect(x: padding, y: videoSize.height - h - padding, width: w, height: h)
        default:
            return CGRect(x: videoSize.width - w - padding,
                          y: videoSize.height - h - padding,
                          width: w, height: h)
        }
    }

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

        let displayWidth = abs(naturalSize.width * transform.a) + abs(naturalSize.height * transform.c)
        let displayHeight = abs(naturalSize.width * transform.b) + abs(naturalSize.height * transform.d)
        let finalSize = CGSize(width: displayWidth, height: displayHeight)

        videoComposition.renderSize = finalSize

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: finalSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let wmLayer = CALayer()
        wmLayer.contents = wmImage.cgImage
        wmLayer.contentsGravity = .resizeAspect

        let targetWidth = finalSize.width * 0.20
        let aspectRatio = wmImage.size.height / wmImage.size.width
        let targetHeight = targetWidth * aspectRatio
        let wmSize = CGSize(width: targetWidth, height: targetHeight)

        var wmFrame = watermarkFrame(videoSize: finalSize, wmSize: wmSize, position: watermarkPosition)

        let isPortrait = finalSize.height > finalSize.width
        if isPortrait {
            wmFrame.origin.y = finalSize.height - wmFrame.maxY
        }

        wmLayer.frame = wmFrame
        wmLayer.opacity = 1.0
        parentLayer.addSublayer(wmLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let tempDir = FileManager.default.temporaryDirectory
        let outName = "VID_WM_\(Int(Date().timeIntervalSince1970)).mov"
        let outURL = tempDir.appendingPathComponent(outName)

        guard let exporter = AVAssetExportSession(asset: mixComposition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
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
                completion(outURL)
            default:
                completion(nil)
            }
        }
    }

    private func saveToPhotosAndExport(url: URL) {
        var savedLocalId: String?

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            savedLocalId = request?.placeholderForCreatedAsset?.localIdentifier
        }) { success, error in
            if let error = error {
                NSLog("[VideoRecorder] Error saving to Photos: \(error)")
            }

            try? FileManager.default.removeItem(at: url)

            guard success, let localId = savedLocalId else { return }
            self.fetchAndExportAsset(localId: localId, attempt: 1)
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

            let tempDir = FileManager.default.temporaryDirectory
            let exportFilename = "VID_EXPORT_\(Int(Date().timeIntervalSince1970)).mov"
            let exportUrl = tempDir.appendingPathComponent(exportFilename)

            guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
                return
            }

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
}

// AVCaptureFileOutputRecordingDelegate

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

// AVCaptureVideoDataOutputSampleBufferDelegate (preview)

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        let now = Date().timeIntervalSince1970
        let minInterval = previewTargetFps > 0 ? (1.0 / Double(previewTargetFps)) : 0.0
        if minInterval > 0 && now - lastPreviewSentAt < minInterval {
            return
        }
        lastPreviewSentAt = now

        guard let cbId = previewCallbackId else {
            if previewEnabled {
                DispatchQueue.main.async { [weak self] in
                    self?.previewEnabled = false
                    self?.stopPreviewSession()
                }
            }
            return
        }

        guard let jpeg = jpegDataFromSampleBuffer(sampleBuffer, quality: previewJpegQuality) else {
            return
        }

        let b64 = jpeg.base64EncodedString(options: [])
        let dataUri = "data:image/jpeg;base64,\(b64)"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let pluginResult = CDVPluginResult(status: .ok, messageAs: dataUri)
            pluginResult?.setKeepCallbackAs(true)
            self.commandDelegate.send(pluginResult, callbackId: cbId)
        }
    }
}