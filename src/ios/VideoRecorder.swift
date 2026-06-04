import Foundation
import AVFoundation
import Photos
import Cordova

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

        NSLog("[VideoRecorder] start called, maxLength=\(maxLengthSec), resolution=\(videoWidth)x\(videoHeight), camera=\(cameraPosition == .front ? "front" : "back"), saveToGallery=\(saveToGallery)")

        startBackgroundTask()
        setupSession()
        startRecording()

        let result = CDVPluginResult(status: .ok)
        self.commandDelegate.send(result, callbackId: command.callbackId)
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

    // MARK: - Save to Photos + Export

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

            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                NSLog("[VideoRecorder] Failed to delete original file: \(String(describing: error))")
            }

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

        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, error in

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

        if saveToGallery {
            saveToPhotosAndExport(url: outputFileURL)
        } else {
            dispatchFinalUrl("file://\(outputFileURL.path)")
        }
    }
}
