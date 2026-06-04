import Foundation
import AVFoundation
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
    var cameraPosition: AVCaptureDevice.Position = .back   // "front" | "back"

    @objc(start:)
    func start(command: CDVInvokedUrlCommand) {
        self.callbackId = command.callbackId

        let options = command.arguments.first as? [String: Any] ?? [:]

        // maxLength
        maxLengthSec = options["maxLength"] as? Int ?? 0

        // bitrate (not directly applied on iOS with AVCaptureMovieFileOutput, but kept for API parity)
        bitrate = options["bitrate"] as? Int ?? 10_000_000

        // resolution
        if let res = options["resolution"] as? String {
            let parts = res.lowercased().split(separator: "x")
            if parts.count == 2 {
                if let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                    videoWidth = w
                    videoHeight = h
                }
            }
        }

        // camera: "front" | "back"
        if let cam = options["camera"] as? String {
            if cam.lowercased() == "front" {
                cameraPosition = .front
            } else {
                cameraPosition = .back
            }
        } else {
            cameraPosition = .back
        }

        startBackgroundTask()
        setupSession()
        startRecording()

        let result = CDVPluginResult(status: .ok)
        self.commandDelegate.send(result, callbackId: command.callbackId)
    }

    @objc(stop:)
    func stop(command: CDVInvokedUrlCommand) {
        self.callbackId = command.callbackId
        stopRecording()
    }

    private func setupSession() {
        let session = AVCaptureSession()
        captureSession = session
        session.beginConfiguration()

        // Map resolution to preset
        if videoWidth >= 3840 || videoHeight >= 2160 {
            if session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }
        } else if videoWidth >= 1920 || videoHeight >= 1080 {
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }
        } else if videoWidth >= 1280 || videoHeight >= 720 {
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else {
                session.sessionPreset = .medium
            }
        } else {
            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            } else {
                session.sessionPreset = .low
            }
        }

        // Select camera
        var videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                  for: .video,
                                                  position: cameraPosition)

        // Fallback to back camera
        if videoDevice == nil {
            videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                  for: .video,
                                                  position: .back)
        }

        guard let vDevice = videoDevice,
              let videoInput = try? AVCaptureDeviceInput(device: vDevice),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            return
        }
        session.addInput(videoInput)

        // Audio
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        // Movie output
        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            self.movieOutput = movieOutput
        }

        session.commitConfiguration()
    }

    private func startRecording() {
        guard let movieOutput = self.movieOutput,
              let session = self.captureSession else { return }

        // Output file
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "VID_\(formatter.string(from: Date())).mov"
        let fileUrl = docs.appendingPathComponent(filename)
        self.outputUrl = fileUrl

        // Background audio mode keeps camera alive
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers])
        try? audioSession.setActive(true)

        // Orientation + stabilization
        if let connection = movieOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        // maxLength
        if maxLengthSec > 0 {
            movieOutput.maxRecordedDuration = CMTime(seconds: Double(maxLengthSec), preferredTimescale: 1)

            // Safety timer (iOS sometimes delays delegate callback)
            stopTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(maxLengthSec + 2),
                                             repeats: false) { [weak self] _ in
                self?.stopRecording()
            }
        }

        session.startRunning()
        movieOutput.startRecording(to: fileUrl, recordingDelegate: self)
    }

    private func stopRecording() {
        stopTimer?.invalidate()
        stopTimer = nil

        movieOutput?.stopRecording()
        // captureSession will be stopped in didFinishRecording
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
}

extension VideoRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {

        // Stop session here to avoid killing recording too early
        captureSession?.stopRunning()
        captureSession = nil
        movieOutput = nil

        // Deactivate audio session
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false)

        endBackgroundTask()

        let path = outputFileURL.path

        let js = """
        document.dispatchEvent(new CustomEvent('VideoRecorderFinished', {
            detail: { file: '\(path)' }
        }));
        """

        self.webViewEngine.evaluateJavaScript(js)
    }
}
