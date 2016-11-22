//
//  ViewController.swift
//  AssetWriterIssue
//
//  Created by Blixt on 11/22/16.
//  Copyright © 2016 47 Center, Inc. All rights reserved.
//

import AVFoundation
import UIKit

class ViewController: UIViewController, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    @IBOutlet weak var logOutputLabel: UILabel!
    @IBOutlet weak var stopRecordingButton: UIButton!

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let url = temporaryFileURL("mp4")
        let quality = MediaWriterQuality.medium

        self.asset = try! AVAssetWriter(url: url, fileType: AVFileTypeMPEG4)
        // FIXME: We need these properties, but they currently break the recording.
        self.asset.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 1000000000)
        //self.asset.shouldOptimizeForNetworkUse = true

        self.audioWriter = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: quality.audioSettings)
        self.audioWriter.expectsMediaDataInRealTime = true
        self.asset.add(self.audioWriter)

        self.videoWriter = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: quality.videoSettings)
        self.videoWriter.expectsMediaDataInRealTime = true
        self.asset.add(self.videoWriter)

        let screenPixels = UIScreen.main.nativeBounds
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Int32(kCVPixelFormatType_32BGRA)),
            kCVPixelBufferWidthKey as String: screenPixels.width,
            kCVPixelBufferHeightKey as String: screenPixels.height,
            ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: self.videoWriter, sourcePixelBufferAttributes: attributes)

        // Set up video preview layer.
        self.previewLayer = AVCaptureVideoPreviewLayer(session: self.capture)!
        self.previewLayer.frame = UIScreen.main.bounds
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
        self.view.layer.insertSublayer(self.previewLayer, at: 0)

        // Route the audio to the capture session.
        self.capture.automaticallyConfiguresApplicationAudioSession = false
        if let audio = self.audio, self.capture.canAddInput(audio) {
            self.capture.addInput(audio)
        } else {
            self.log("Failed to add audio input")
        }
        self.capture.addOutput(self.audioOutput)
        self.capture.addOutput(self.videoOutput)
        self.audioOutput.setSampleBufferDelegate(self, queue: self.queue)
        self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Int32(kCVPixelFormatType_32BGRA))]
        self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
        // Custom audio session configuration.
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(AVAudioSessionCategoryPlayAndRecord, with: [.mixWithOthers])
            try audio.setActive(true, with: .notifyOthersOnDeactivation)
        } catch {
            self.log("Failed to set Audio Session: \(error)")
        }

        self.queue.async {
            self.configureDevice(camera: self.back, microphone: .back)
            self.capture.startRunning()
            if !self.asset.startWriting() {
                self.log("Asset writer failed to start")
                if let error = self.asset.error {
                    self.log("Asset writer error: \(error)")
                }
            }
        }
    }

    @IBAction func stopRecordingButtonTapped(_ sender: Any) {
        self.capture.stopRunning()
        self.previewLayer.removeFromSuperlayer()
        self.stopRecordingButton.isHidden = true
        self.finish {
            self.log("Finished recording")
        }
    }

    func finish(callback: @escaping () -> ()) {
        // Clean up and complete writing.
        self.audioWriter.markAsFinished()
        self.videoWriter.markAsFinished()
        self.asset.finishWriting {
            if self.asset.status != .completed {
                self.log("Asset writer finished with status \(self.asset.status.rawValue)")
                if let error = self.asset.error {
                    self.log("Asset writer error: \(error)")
                }
            }
            // Let the UI know as soon as the file is ready.
            callback()
        }
    }

    func log(_ line: String) {
        NSLog("%@", line)
        DispatchQueue.main.async {
            let lines = self.logOutputLabel.text!.components(separatedBy: "\n") + ["\(Date()) \(line)"]
            self.logOutputLabel.text = lines.suffix(50).joined(separator: "\n")
            self.logOutputLabel.sizeToFit()
        }
    }

    // MARK: - AVCapture{Audio,Video}DataOutputSampleBufferDelegate

    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        switch captureOutput {
        case self.audioOutput:
            self.appendAudio(sampleBuffer)
        case self.videoOutput:
            self.appendVideo(sampleBuffer)
        default:
            preconditionFailure("unknown capture output: \(captureOutput)")
        }
    }

    // MARK: - Private

    private let appendFramePixelBufferQueue = DispatchQueue(label: "io.fika.Fika.AppendFramePixelBufferQueue")
    private let audioOutput = AVCaptureAudioDataOutput()
    private let capture = AVCaptureSession()
    private let minDelta = CMTime(value: 15000000, timescale: 1000000000)
    private let queue = DispatchQueue(label: "io.fika.Fika.Recorder", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()

    private var adaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var asset: AVAssetWriter!
    private var audioWriter, videoWriter: AVAssetWriterInput!
    private var cameraLocked = false
    private var currentCamera: AVCaptureDeviceInput?
    private var lastVideoTimestamp = CMTime(value: 0, timescale: 1)
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var writerSessionStarted = false

    private lazy var audio: AVCaptureDeviceInput? = self.input(AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeAudio))
    private lazy var back: AVCaptureDeviceInput? = self.input(AVCaptureDevice.defaultDevice(withDeviceType: .builtInWideAngleCamera, mediaType: AVMediaTypeVideo, position: .back))
    private lazy var front: AVCaptureDeviceInput? = self.input(AVCaptureDevice.defaultDevice(withDeviceType: .builtInWideAngleCamera, mediaType: AVMediaTypeVideo, position: .front))

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer), self.audioWriter.isReadyForMoreMediaData else {
            return false
        }
        if !self.writerSessionStarted {
            // Wait for video before writing any audio (because audio may arrive much sooner than video).
            return false
        }
        return self.audioWriter.append(sampleBuffer)
    }

    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return false
        }
        // Short-circuit video render logic by appending the original buffer directly.
        self.appendFramePixelBufferQueue.sync {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            self.safelyAppendVideo(buffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        return true
    }

    private func configureDevice(camera: AVCaptureDeviceInput?, microphone: Microphone) {
        self.capture.beginConfiguration()
        let cameraChanged = self.currentCamera !== camera
        // Stop capturing input from the previous camera if it changed.
        if cameraChanged, let input = self.currentCamera {
            self.capture.removeInput(input)
            if self.cameraLocked {
                input.device.unlockForConfiguration()
                self.cameraLocked = false
            }
        }
        self.currentCamera = camera
        // Set up the audio route.
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.overrideOutputAudioPort(.speaker)
        } catch {
            self.log("Failed to override audio port: \(error)")
        }
        if let orientation = microphone.orientation, let mic = audio.inputDataSources?.first(where: { $0.orientation == orientation }), audio.inputDataSource != mic {
            do {
                try audio.setInputDataSource(mic)
            } catch {
                self.log("Failed to use \(orientation) microphone: \(error)")
            }
        }
        // Configure the selected camera.
        guard let input = camera else {
            // There is no camera (audio only).
            self.capture.commitConfiguration()
            return
        }
        if cameraChanged {
            // Lock the camera so we can update its properties.
            precondition(!self.cameraLocked, "camera shouldn't be locked")
            do {
                try input.device.lockForConfiguration()
                self.cameraLocked = true
                // Configure the camera for 30 FPS.
                input.device.activeVideoMinFrameDuration = CMTimeMake(1, 30)
                input.device.activeVideoMaxFrameDuration = CMTimeMake(1, 30)
            } catch {
                self.log("Failed to lock camera for configuration: \(error)")
            }
            // Set up data input.
            if self.capture.canAddInput(input) {
                self.capture.addInput(input)
                if let connection = self.videoOutput.connection(withMediaType: AVMediaTypeVideo) {
                    connection.videoOrientation = .portrait
                    connection.isVideoMirrored = camera == self.front
                }
            } else {
                self.log("Failed to set up camera.")
            }
        }
        self.capture.commitConfiguration()
    }

    private func ensureSessionStarted(buffer sampleBuffer: CMSampleBuffer) {
        self.ensureSessionStarted(time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func ensureSessionStarted(time: CMTime) {
        guard !self.writerSessionStarted else {
            return
        }
        self.asset.startSession(atSourceTime: time)
        self.writerSessionStarted = true
    }

    private func input(_ device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let device = device else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }

    @discardableResult
    private func safelyAppendVideo(_ buffer: CVPixelBuffer, timestamp: CMTime) -> Bool {
        guard self.videoWriter.isReadyForMoreMediaData else {
            self.log("Dropped a video frame because writer was not ready")
            return false
        }
        guard timestamp - self.minDelta > self.lastVideoTimestamp else {
            self.log("Dropped a video frame due to negative/low time delta")
            return false
        }
        self.ensureSessionStarted(time: timestamp)
        if !self.adaptor.append(buffer, withPresentationTime: timestamp) {
            // TODO: Check the asset writer status and notify if it failed.
            self.log("Failed to append a frame to pixel buffer")
            return false
        }
        self.lastVideoTimestamp = timestamp
        return true
    }
}

enum Configuration {
    case audioOnly, backCamera, frontCamera
}

enum MediaWriterQuality {
    case medium

    var audioSettings: [String: Any] {
        let bitRate, sampleRate: Int
        switch self {
        case .medium:
            bitRate = 64000
            sampleRate = 44100
        }
        return [
            AVNumberOfChannelsKey: NSNumber(value: 1),
            AVEncoderBitRatePerChannelKey: NSNumber(value: bitRate),
            AVFormatIDKey: NSNumber(value: kAudioFormatMPEG4AAC),
            AVSampleRateKey: NSNumber(value: sampleRate),
        ]
    }

    var videoSettings: [String: Any] {
        let bitRate, height, width: Int
        switch self {
        case .medium:
            bitRate = 819200
            height = 1152
            width = 648
        }
        return [
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: NSNumber(value: true),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
                AVVideoMaxKeyFrameIntervalDurationKey: NSNumber(value: 1),
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: NSNumber(value: 30),
                AVVideoAverageBitRateKey: NSNumber(value: bitRate),
                "Priority": NSNumber(value: 80),
                "RealTime": NSNumber(value: true),
            ],
            AVVideoHeightKey: NSNumber(value: height),
            AVVideoWidthKey: NSNumber(value: width),
        ]
    }
}

enum Microphone {
    case back, bottom, front, ignore

    var orientation: String? {
        switch self {
        case .back:
            return AVAudioSessionOrientationBack
        case .bottom:
            return AVAudioSessionOrientationBottom
        case .front:
            return AVAudioSessionOrientationFront
        case .ignore:
            return nil
        }
    }
}

fileprivate func temporaryFileURL(_ fileExtension: String) -> URL {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let randomId = ProcessInfo.processInfo.globallyUniqueString
    return temp.appendingPathComponent(randomId).appendingPathExtension(fileExtension)
}
