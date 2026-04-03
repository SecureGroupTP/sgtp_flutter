import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    FlutterMethodChannel(
      name: "com.example.sgtp_flutter/video_merger",
      binaryMessenger: controller.binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      guard call.method == "mergeVideoAudio" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: String],
        let videoPath = args["videoPath"],
        let audioPath = args["audioPath"],
        let outputPath = args["outputPath"]
      else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
        return
      }
      self?.mergeVideoAudio(videoPath: videoPath, audioPath: audioPath, outputPath: outputPath) { error in
        if let error = error {
          result(FlutterError(code: "MERGE_FAILED", message: error.localizedDescription, details: nil))
        } else {
          result(outputPath)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func mergeVideoAudio(
    videoPath: String,
    audioPath: String,
    outputPath: String,
    completion: @escaping (Error?) -> Void
  ) {
    let composition = AVMutableComposition()
    let videoAsset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    let audioAsset = AVURLAsset(url: URL(fileURLWithPath: audioPath))

    guard
      let compVideoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let compAudioTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
      let srcVideoTrack = videoAsset.tracks(withMediaType: .video).first,
      let srcAudioTrack = audioAsset.tracks(withMediaType: .audio).first
    else {
      completion(NSError(
        domain: "VideoMerger", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Could not find video or audio track"]))
      return
    }

    let videoDuration = videoAsset.duration
    let audioDuration = audioAsset.duration
    let mergeDuration = CMTimeMinimum(videoDuration, audioDuration)

    do {
      try compVideoTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: videoDuration),
        of: srcVideoTrack, at: .zero)
      try compAudioTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: mergeDuration),
        of: srcAudioTrack, at: .zero)
    } catch {
      completion(error)
      return
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outputURL)

    guard let session = AVAssetExportSession(
      asset: composition, presetName: AVAssetExportPresetPassthrough)
    else {
      completion(NSError(
        domain: "VideoMerger", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Could not create export session"]))
      return
    }

    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.exportAsynchronously {
      switch session.status {
      case .completed:
        completion(nil)
      case .failed:
        completion(session.error ?? NSError(domain: "VideoMerger", code: -3, userInfo: nil))
      default:
        completion(NSError(
          domain: "VideoMerger", code: -4,
          userInfo: [NSLocalizedDescriptionKey: "Export cancelled or unknown error"]))
      }
    }
  }
}
