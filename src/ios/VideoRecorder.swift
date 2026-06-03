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

        // bitrate
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
        captureSession = AVCaptureSession()
        captureSession?.beginConfiguration()

        // Map bitrate to preset
        if bitrate >= 20_000_000 {
            captureSession?.sessionPreset = .high
        } else if bitrate >= 8_000_000 {
            captureSession?.sessionPreset = .medium
        } else {
            captureSession?.sessionPreset = .low
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
              captureSession!.canAddInput(videoInput) else {
            return
        }
        captureSession!.addInput(videoInput)

        // Audio
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession!.canAddInput(audioInput) {
            captureSession!.addInput(audioInput)
        }

        // Movie output
        let movieOutput = AVCaptureMovieFileOutput()
        if captureSession!.canAddOutput(movieOutput) {
            captureSession!.addOutput(movieOutput)
            self.movieOutput = movieOutput
        }

        captureSession?.commitConfiguration()
    }

    private func startRecording() {
        guard let movieOutput = self.movieOutput else { return }

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

        captureSession?.startRunning()
        movieOutput.startRecording(to: fileUrl, recordingDelegate: self)
    }

    private func stopRecording() {
        stopTimer?.invalidate()
        stopTimer = nil

        movieOutput?.stopRecording()
        captureSession?.stopRunning()
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
