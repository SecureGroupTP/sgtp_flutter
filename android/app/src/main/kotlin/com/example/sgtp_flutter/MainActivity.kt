package com.example.sgtp_flutter

import android.net.Uri
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {

    private val videoMergerChannel = "com.example.sgtp_flutter/video_merger"
    private val keyboardContentChannel = "com.example.sgtp_flutter/keyboard_content"
    private val notificationHostChannel = "com.example.sgtp_flutter/notification_host_android"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, videoMergerChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "mergeVideoAudio") {
                    val videoPath = call.argument<String>("videoPath") ?: run {
                        result.error("INVALID_ARGS", "videoPath missing", null); return@setMethodCallHandler
                    }
                    val audioPath = call.argument<String>("audioPath") ?: run {
                        result.error("INVALID_ARGS", "audioPath missing", null); return@setMethodCallHandler
                    }
                    val outputPath = call.argument<String>("outputPath") ?: run {
                        result.error("INVALID_ARGS", "outputPath missing", null); return@setMethodCallHandler
                    }
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            mergeVideoAudio(videoPath, audioPath, outputPath)
                            withContext(Dispatchers.Main) { result.success(outputPath) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("MERGE_FAILED", e.message, null)
                            }
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, keyboardContentChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "readContentUriBytes") {
                    val rawUri = call.argument<String>("uri") ?: run {
                        result.error("INVALID_ARGS", "uri missing", null)
                        return@setMethodCallHandler
                    }
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val bytes = readContentUriBytes(rawUri)
                            withContext(Dispatchers.Main) { result.success(bytes) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("READ_CONTENT_FAILED", e.message, null)
                            }
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationHostChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        NotificationHostService.ensureChannel(this)
                        result.success("supported")
                    }
                    "start" -> {
                        val accountId = call.argument<String>("accountId")?.trim().orEmpty()
                        if (accountId.isEmpty()) {
                            result.error("INVALID_ACCOUNT", "accountId missing", null)
                            return@setMethodCallHandler
                        }
                        if (!NotificationHostService.areNotificationsEnabled(this)) {
                            result.error("PERMISSION_DENIED", "Notifications are disabled", null)
                            return@setMethodCallHandler
                        }
                        NotificationHostService.start(this, accountId)
                        result.success(null)
                    }
                    "stop" -> {
                        NotificationHostService.stop(this)
                        result.success(null)
                    }
                    "stopForAccount" -> {
                        val accountId = call.argument<String>("accountId")?.trim().orEmpty()
                        NotificationHostService.stopForAccount(this, accountId)
                        result.success(null)
                    }
                    "isRunning" -> {
                        result.success(NotificationHostService.isRunning)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun readContentUriBytes(rawUri: String): ByteArray {
        val uri = Uri.parse(rawUri)
        val stream = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("Unable to open content URI: $rawUri")
        stream.use { input -> return input.readBytes() }
    }

    private fun mergeVideoAudio(videoPath: String, audioPath: String, outputPath: String) {
        val videoExtractor = MediaExtractor().apply { setDataSource(videoPath) }
        val audioExtractor = MediaExtractor().apply { setDataSource(audioPath) }

        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        // Select video track
        var videoTrackIndex = -1
        var muxerVideoTrack = -1
        var videoDurationUs = Long.MAX_VALUE
        for (i in 0 until videoExtractor.trackCount) {
            val fmt = videoExtractor.getTrackFormat(i)
            if ((fmt.getString(MediaFormat.KEY_MIME) ?: "").startsWith("video/")) {
                videoExtractor.selectTrack(i)
                videoTrackIndex = i
                muxerVideoTrack = muxer.addTrack(fmt)
                if (fmt.containsKey(MediaFormat.KEY_DURATION))
                    videoDurationUs = fmt.getLong(MediaFormat.KEY_DURATION)
                break
            }
        }

        // Select audio track
        var audioTrackIndex = -1
        var muxerAudioTrack = -1
        for (i in 0 until audioExtractor.trackCount) {
            val fmt = audioExtractor.getTrackFormat(i)
            if ((fmt.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) {
                audioExtractor.selectTrack(i)
                audioTrackIndex = i
                muxerAudioTrack = muxer.addTrack(fmt)
                break
            }
        }

        if (videoTrackIndex == -1 || audioTrackIndex == -1) {
            videoExtractor.release(); audioExtractor.release(); muxer.release()
            throw Exception("Could not find video or audio track")
        }

        muxer.start()
        val buf = ByteBuffer.allocate(2 * 1024 * 1024)
        val info = MediaCodec.BufferInfo()

        // Write video samples
        while (true) {
            val size = videoExtractor.readSampleData(buf, 0)
            if (size < 0) break
            info.set(0, size, videoExtractor.sampleTime, videoExtractor.sampleFlags)
            muxer.writeSampleData(muxerVideoTrack, buf, info)
            videoExtractor.advance()
        }

        // Write audio samples up to video duration
        while (true) {
            val size = audioExtractor.readSampleData(buf, 0)
            if (size < 0) break
            val pts = audioExtractor.sampleTime
            if (pts > videoDurationUs) break
            info.set(0, size, pts, audioExtractor.sampleFlags)
            muxer.writeSampleData(muxerAudioTrack, buf, info)
            audioExtractor.advance()
        }

        muxer.stop()
        muxer.release()
        videoExtractor.release()
        audioExtractor.release()
    }
}
