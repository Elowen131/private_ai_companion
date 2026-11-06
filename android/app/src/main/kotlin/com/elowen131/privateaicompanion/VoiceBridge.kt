package com.elowen131.privateaicompanion

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * 语音能力桥（`private_ai_companion/voice`）。
 *
 * 为什么全部走原生而不是第三方插件：本工程是**全离线**交付，pub 源不可用，
 * 引入 `record` / `just_audio` / `speech_to_text` 需要联网解析依赖。而 Android
 * 自带的 MediaRecorder / MediaPlayer / TextToSpeech / SpeechRecognizer /
 * MediaCodec 已覆盖全部需求，且不需要任何额外 APK 体积。
 *
 * 能力清单与诚实边界：
 * - 声纹：解码任意含音轨的音频/视频 → 16k 单声道 → 基频、共振峰带宽能量、
 *   过零率等 16 维特征。这是**真实的说话人特征描述**（可用于区分角色音色），
 *   但不是深度声纹模型，不宣称「声音克隆」。
 * - 合成：Android TTS 不支持音色克隆，因此按声纹的基频/能量映射 TTS 的
 *   pitch / rate，得到**近似该角色音色**的朗读。要真·克隆需外接 TTS 模型。
 * - 识别：系统 SpeechRecognizer，优先离线（EXTRA_PREFER_OFFLINE），
 *   设备无离线包时会回落到在线识别；完全不可用时明确返回 UNAVAILABLE。
 */
class VoiceBridge(
    private val activity: Activity,
    private val messenger: io.flutter.plugin.common.BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val CHANNEL = "private_ai_companion/voice"
        const val STT_EVENTS = "private_ai_companion/voice_stt"
        const val REQ_PICK = 2001
        const val REQ_CREDENTIAL = 2002
        private const val TARGET_RATE = 16000
    }

    private val main = Handler(Looper.getMainLooper())
    /** utteranceId -> (回调, 输出路径)：synthesizeToFile 是异步的，结果在监听器里回来。 */
    private val pendingSynth =
        java.util.concurrent.ConcurrentHashMap<String, Pair<MethodChannel.Result, String>>()
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val pendingSpeech = mutableListOf<Triple<String, Float, Float>>()

    private var recorder: MediaRecorder? = null
    private var recordPath: String? = null
    private var recordStartedAt = 0L
    private var player: MediaPlayer? = null

    private var recognizer: SpeechRecognizer? = null
    private var sttSink: EventChannel.EventSink? = null
    private var sttActive = false

    private var pickResult: MethodChannel.Result? = null
    private var credentialResult: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null
    private var pendingPermission: String? = null

    private lateinit var channel: MethodChannel

    fun register() {
        channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler(this)
        EventChannel(messenger, STT_EVENTS).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "deviceInfo" -> result.success(deviceInfo())
            "speak" -> {
                val text = call.argument<String>("text") ?: ""
                val pitch = (call.argument<Double>("pitch") ?: 1.0).toFloat()
                val rate = (call.argument<Double>("rate") ?: 1.0).toFloat()
                if (text.isBlank()) {
                    result.success(false)
                    return
                }
                speak(text, pitch, rate, result)
            }
            "synthesize" -> synthesize(
                call.argument<String>("text") ?: "",
                call.argument<String>("path") ?: "",
                (call.argument<Double>("pitch") ?: 1.0).toFloat(),
                (call.argument<Double>("rate") ?: 1.0).toFloat(),
                result
            )
            "listTtsVoices" -> listTtsVoices(result)
            "setTtsVoice" -> setTtsVoice(
                call.argument<String>("name") ?: "",
                result
            )
            "stopSpeak" -> {
                try {
                    tts?.stop()
                } catch (_: Exception) {
                }
                result.success(true)
            }
            "startRecord" -> startRecord(call.argument<String>("path") ?: "", result)
            "stopRecord" -> stopRecord(result)
            "cancelRecord" -> cancelRecord(result)
            "play" -> play(call.argument<String>("path") ?: "", result)
            "stopPlay" -> {
                stopPlay()
                result.success(true)
            }
            "analyzeVoice" -> analyzeVoice(
                call.argument<String>("path") ?: "",
                call.argument<String>("outDir") ?: activity.cacheDir.absolutePath,
                result
            )
            "pickMedia" -> pickMedia(call.argument<String>("kind") ?: "audio", result)
            "sttStart" -> sttStart(call.argument<String>("locale") ?: "zh-CN", result)
            "sttStop" -> {
                stopStt()
                result.success(true)
            }
            "permissionState" -> result.success(permissionState(call.argument<String>("name") ?: ""))
            "requestPermission" -> requestPermission(call.argument<String>("name") ?: "", result)
            "credentialAvailable" -> result.success(credentialAvailable())
            "authDeviceCredential" -> authDeviceCredential(
                call.argument<String>("title") ?: "解锁以继续", result
            )
            else -> result.notImplemented()
        }
    }

    // ---------------- 能力探测 ----------------

    private fun capabilities(): Map<String, Any> {
        var ttsOk = false
        try {
            val i = Intent(TextToSpeech.Engine.ACTION_CHECK_TTS_DATA)
            ttsOk = activity.packageManager.queryIntentActivities(i, 0).isNotEmpty()
        } catch (_: Exception) {
        }
        return mapOf(
            "tts" to ttsOk,
            "stt" to SpeechRecognizer.isRecognitionAvailable(activity),
            "recorder" to true,
            "player" to true,
            "analyzer" to true,
            "credential" to credentialAvailable(),
        )
    }

    private fun deviceInfo(): Map<String, Any> {
        val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val mi = android.app.ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "cores" to Runtime.getRuntime().availableProcessors(),
            "totalRamMb" to (mi.totalMem / (1024 * 1024)).toInt(),
            "lowRam" to am.isLowRamDevice,
            "abi" to Build.SUPPORTED_ABIS.joinToString(","),
        )
    }

    // ---------------- TTS ----------------

    private fun ensureTts() {
        if (tts != null) return
        tts = TextToSpeech(activity) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) {
                try {
                    tts?.language = Locale.SIMPLIFIED_CHINESE
                    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {}
                        override fun onDone(utteranceId: String?) {
                            resolveSynth(utteranceId, true)
                        }
                        @Deprecated("兼容旧 API")
                        override fun onError(utteranceId: String?) {
                            resolveSynth(utteranceId, false)
                        }
                    })
                } catch (_: Exception) {
                }
                val queue = pendingSpeech.toList()
                pendingSpeech.clear()
                queue.forEach { (t, p, r) -> speakNow(t, p, r) }
            }
        }
    }

    /**
     * 列出系统 TTS 里的发音人。
     *
     * 同一条引擎往往装了多个（不同性别 / 语言 / 音质），让用户给不同角色
     * 挑不同的人——这是**完全离线**就能做出的音色区分。
     */
    private fun listTtsVoices(result: MethodChannel.Result) {
        ensureTts()
        if (!ttsReady) {
            // 初始化是异步的，这里不报「失败」而是让上层知道「还没好」。
            result.error("TTS_NOT_READY", "语音引擎还在初始化，稍后再试", null)
            return
        }
        val out = ArrayList<Map<String, Any?>>()
        try {
            tts?.voices?.forEach { v ->
                out.add(
                    mapOf(
                        "name" to v.name,
                        "locale" to v.locale.toLanguageTag(),
                        "quality" to v.quality,
                        "latency" to v.latency,
                        "network" to v.isNetworkConnectionRequired,
                        "notInstalled" to v.features.contains("notInstalled")
                    )
                )
            }
        } catch (_: Exception) {
        }
        out.sortBy { it["name"] as String }
        result.success(out)
    }

    private fun setTtsVoice(name: String, result: MethodChannel.Result) {
        ensureTts()
        if (!ttsReady) {
            result.error("TTS_NOT_READY", "语音引擎还在初始化，稍后再试", null)
            return
        }
        if (name.isBlank()) {
            result.success(tts?.setVoice(tts?.defaultVoice) == TextToSpeech.SUCCESS)
            return
        }
        val v = try {
            tts?.voices?.firstOrNull { it.name == name }
        } catch (_: Exception) {
            null
        }
        if (v == null) {
            result.error("VOICE_NOT_FOUND", "系统里已经没有这个发音人了，可能被卸载", null)
            return
        }
        result.success(tts?.setVoice(v) == TextToSpeech.SUCCESS)
    }

    private fun speak(text: String, pitch: Float, rate: Float, result: MethodChannel.Result) {
        ensureTts()
        val safePitch = pitch.coerceIn(0.4f, 2.0f)
        val safeRate = rate.coerceIn(0.5f, 2.0f)
        if (!ttsReady) {
            // TTS 初始化是异步的：先排队，语义上「已接受」，不让 UI 报错。
            pendingSpeech.add(Triple(text, safePitch, safeRate))
            result.success(true)
            return
        }
        result.success(speakNow(text, safePitch, safeRate))
    }

    private fun speakNow(text: String, pitch: Float, rate: Float): Boolean {
        return try {
            tts?.setPitch(pitch)
            tts?.setSpeechRate(rate)
            val r = tts?.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "c_${System.currentTimeMillis()}")
            r == TextToSpeech.SUCCESS
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 把文本合成为本地音频文件（角色语音消息落盘用）。
     *
     * Android TTS 的 synthesizeToFile 是异步的：结果在 UtteranceProgressListener
     * 的 onDone/onError 里回来，所以这里用 utteranceId 建一张待决表。
     */
    private fun synthesize(
        text: String,
        path: String,
        pitch: Float,
        rate: Float,
        result: MethodChannel.Result
    ) {
        if (text.isBlank() || path.isBlank()) {
            result.error("BAD_ARGS", "缺少文本或输出路径", null)
            return
        }
        ensureTts()
        if (!ttsReady) {
            result.error("TTS_NOT_READY", "语音引擎还在初始化，请稍后再试", null)
            return
        }
        val out = File(path)
        try {
            out.parentFile?.mkdirs()
        } catch (_: Exception) {
        }
        val uid = "syn_${System.currentTimeMillis()}"
        pendingSynth[uid] = Pair(result, out.absolutePath)
        try {
            tts?.setPitch(pitch.coerceIn(0.4f, 2.0f))
            tts?.setSpeechRate(rate.coerceIn(0.5f, 2.0f))
            val r = tts?.synthesizeToFile(text, Bundle(), out, uid)
            if (r != TextToSpeech.SUCCESS) {
                pendingSynth.remove(uid)
                result.error("SYNTH_FAILED", "系统拒绝了这次合成请求", null)
            }
        } catch (e: Exception) {
            pendingSynth.remove(uid)
            result.error("SYNTH_FAILED", e.message ?: "合成失败", null)
        }
    }

    private fun resolveSynth(utteranceId: String?, ok: Boolean) {
        val key = utteranceId ?: return
        if (!key.startsWith("syn_")) return
        val entry = pendingSynth.remove(key) ?: return
        val (callback, path) = entry
        val f = File(path)
        if (ok && f.exists() && f.length() > 0) {
            callback.success(mapOf("path" to path, "durationMs" to 0))
        } else {
            try {
                if (f.exists()) f.delete()
            } catch (_: Exception) {
            }
            callback.error("SYNTH_FAILED", "合成没有完成", null)
        }
    }

    // ---------------- 录音 ----------------

    private fun startRecord(path: String, result: MethodChannel.Result) {
        if (recorder != null) {
            result.error("BUSY", "正在录音", null)
            return
        }
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) {
            result.error("NO_PERMISSION", "缺少麦克风权限", null)
            return
        }
        if (path.isEmpty()) {
            result.error("BAD_ARGS", "缺少输出路径", null)
            return
        }
        try {
            File(path).parentFile?.mkdirs()
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(activity)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(44100)
            r.setAudioEncodingBitRate(96000)
            r.setOutputFile(path)
            r.prepare()
            r.start()
            recorder = r
            recordPath = path
            recordStartedAt = System.currentTimeMillis()
            result.success(true)
        } catch (e: Exception) {
            releaseRecorder()
            result.error("RECORD_FAILED", e.message ?: "录音启动失败", null)
        }
    }

    private fun stopRecord(result: MethodChannel.Result) {
        val r = recorder
        if (r == null) {
            result.error("NOT_RECORDING", "当前没有在录音", null)
            return
        }
        val path = recordPath ?: ""
        val duration = System.currentTimeMillis() - recordStartedAt
        try {
            r.stop()
        } catch (e: Exception) {
            // 录音过短时 stop() 会抛 RuntimeException，此时文件不可用。
            releaseRecorder()
            try {
                File(path).delete()
            } catch (_: Exception) {
            }
            result.error("TOO_SHORT", "录音太短，请按住多说一会儿", null)
            return
        }
        releaseRecorder()
        val size = try {
            File(path).length()
        } catch (_: Exception) {
            0L
        }
        if (size <= 0L) {
            result.error("EMPTY", "没有录到声音", null)
            return
        }
        result.success(mapOf("path" to path, "durationMs" to duration, "bytes" to size))
    }

    private fun cancelRecord(result: MethodChannel.Result) {
        val path = recordPath
        releaseRecorder()
        if (path != null) {
            try {
                File(path).delete()
            } catch (_: Exception) {
            }
        }
        result.success(true)
    }

    private fun releaseRecorder() {
        try {
            recorder?.reset()
            recorder?.release()
        } catch (_: Exception) {
        }
        recorder = null
        recordPath = null
    }

    // ---------------- 播放 ----------------

    private fun play(path: String, result: MethodChannel.Result) {
        if (path.isEmpty() || !File(path).exists()) {
            result.error("NOT_FOUND", "文件不存在", null)
            return
        }
        stopPlay()
        try {
            val p = MediaPlayer()
            p.setAudioStreamType(AudioManager.STREAM_MUSIC)
            p.setDataSource(path)
            p.setOnCompletionListener { stopPlay() }
            p.setOnErrorListener { _, _, _ ->
                stopPlay()
                true
            }
            p.prepare()
            val dur = p.duration
            p.start()
            player = p
            result.success(mapOf("ok" to true, "durationMs" to dur))
        } catch (e: Exception) {
            result.error("PLAY_FAILED", e.message ?: "播放失败", null)
        }
    }

    private fun stopPlay() {
        try {
            player?.stop()
            player?.release()
        } catch (_: Exception) {
        }
        player = null
    }

    // ---------------- 声纹分析 ----------------

    /**
     * 解码 → 单声道 16k → 特征。失败原因用稳定的错误码返回，UI 可据此给出
     * 「这个视频没有音轨」这类具体提示，而不是笼统的「分析失败」。
     */
    private fun analyzeVoice(path: String, outDir: String, result: MethodChannel.Result) {
        if (path.isEmpty() || !File(path).exists()) {
            result.error("NOT_FOUND", "文件不存在", null)
            return
        }
        Thread {
            try {
                val pcm = decodeToMono16k(path)
                if (pcm == null || pcm.size < TARGET_RATE / 2) {
                    main.post { result.error("NO_AUDIO", "没有解析到有效音轨，换一段音频或带声音的视频试试", null) }
                    return@Thread
                }
                val features = analyze(pcm)
                File(outDir).mkdirs()
                val out = File(outDir, "voice_${System.currentTimeMillis()}.wav")
                writeWav(out, pcm, TARGET_RATE)
                val map = HashMap<String, Any>()
                map["ok"] = true
                map["playablePath"] = out.absolutePath
                map["durationMs"] = (pcm.size * 1000L / TARGET_RATE)
                map["sampleRate"] = TARGET_RATE
                map.putAll(features)
                main.post { result.success(map) }
            } catch (e: Exception) {
                main.post { result.error("ANALYZE_FAILED", e.message ?: "解析失败", null) }
            }
        }.start()
    }

    /** 用 MediaExtractor + MediaCodec 解出任意容器里的音频，降混为单声道 16k。 */
    private fun decodeToMono16k(path: String): FloatArray? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    track = i
                    format = f
                    break
                }
            }
            if (track < 0 || format == null) return null
            extractor.selectTrack(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            var srcRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE))
                format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
            var channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1

            val chunks = ArrayList<ShortArray>()
            var total = 0L
            val maxSamples = 16000L * 25 // 最多分析 25 秒，够取音色又不会卡 UI
            val info = MediaCodec.BufferInfo()
            var sawEos = false
            var guard = 0
            while (!sawEos && guard < 100000) {
                guard++
                val inIndex = codec.dequeueInputBuffer(5000)
                if (inIndex >= 0) {
                    val buf = codec.getInputBuffer(inIndex)
                    val size = if (buf == null) -1 else extractor.readSampleData(buf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        sawEos = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
                var outIndex = codec.dequeueOutputBuffer(info, 5000)
                while (true) {
                    if (outIndex >= 0) {
                        if (info.size > 0) {
                            val ob = codec.getOutputBuffer(outIndex)
                            if (ob != null) {
                                ob.position(info.offset)
                                ob.limit(info.offset + info.size)
                                val shorts = ShortArray(info.size / 2)
                                ob.order(ByteOrder.nativeOrder()).asShortBuffer().get(shorts)
                                chunks.add(shorts)
                                total += shorts.size
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        outIndex = codec.dequeueOutputBuffer(info, 0)
                    } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        // 输出格式在解码开始后才确定，采样率/声道以此为准。
                        val of = codec.outputFormat
                        if (of.containsKey(MediaFormat.KEY_SAMPLE_RATE))
                            srcRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        if (of.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                            channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        outIndex = codec.dequeueOutputBuffer(info, 0)
                    } else {
                        break
                    }
                }
                if (total > maxSamples * channels) sawEos = true
            }
            codec.stop()
            codec.release()

            if (total == 0L) return null
            val all = ShortArray(total.toInt())
            var off = 0
            for (c in chunks) {
                System.arraycopy(c, 0, all, off, c.size)
                off += c.size
            }
            val frames = all.size / channels
            val mono = FloatArray(frames) { i ->
                var acc = 0f
                for (ch in 0 until channels) acc += all[i * channels + ch] / 32768f
                acc / channels
            }
            return resample(mono, srcRate, TARGET_RATE)
        } catch (e: Exception) {
            return null
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun resample(input: FloatArray, srcRate: Int, dstRate: Int): FloatArray {
        if (srcRate <= 0 || input.isEmpty()) return input
        if (srcRate == dstRate) return input
        val ratio = srcRate.toDouble() / dstRate.toDouble()
        val outLen = (input.size / ratio).toInt().coerceAtLeast(1)
        val out = FloatArray(outLen)
        for (i in 0 until outLen) {
            val pos = i * ratio
            val i0 = pos.toInt().coerceIn(0, input.size - 1)
            val i1 = (i0 + 1).coerceAtMost(input.size - 1)
            val frac = (pos - i0).toFloat()
            out[i] = input[i0] * (1 - frac) + input[i1] * frac
        }
        return out
    }

    /**
     * 16 维说话人特征。取的是可解释的声学量（基频、能量、谱重心、8 个频带
     * 能量占比、过零率、浊音比例），用于区分不同角色的音色并驱动 TTS 参数。
     */
    private fun analyze(pcm: FloatArray): Map<String, Any> {
        val frame = 1024
        val hop = 512
        val bandCenters = intArrayOf(180, 380, 700, 1200, 1800, 2600, 3600, 5200)
        val bandEnergy = DoubleArray(bandCenters.size)
        val f0s = ArrayList<Double>()
        var energySum = 0.0
        var zcrSum = 0.0
        var centroidSum = 0.0
        var frames = 0
        var pos = 0
        while (pos + frame <= pcm.size) {
            var rms = 0.0
            var zcr = 0
            for (i in 0 until frame) {
                val v = pcm[pos + i].toDouble()
                rms += v * v
                if (i > 0 && (pcm[pos + i] >= 0) != (pcm[pos + i - 1] >= 0)) zcr++
            }
            rms = sqrt(rms / frame)
            energySum += rms
            zcrSum += zcr.toDouble() / frame
            frames++

            // 基频：去均值后的自相关峰（50~500Hz）。
            if (rms > 0.005) {
                var mean = 0.0
                for (i in 0 until frame) mean += pcm[pos + i]
                mean /= frame
                var bestLag = -1
                var bestVal = 0.0
                var zero = 0.0
                for (i in 0 until frame) {
                    val v = pcm[pos + i] - mean
                    zero += v * v
                }
                if (zero <= 1e-9) {
                    // 静音帧
                } else {
                    val minLag = TARGET_RATE / 500
                    val maxLag = (TARGET_RATE / 50).coerceAtMost(frame / 2)
                    for (lag in minLag..maxLag) {
                        var acc = 0.0
                        var n = 0
                        var i = 0
                        while (i + lag < frame) {
                            acc += (pcm[pos + i] - mean) * (pcm[pos + i + lag] - mean)
                            n++
                            i++
                        }
                        val norm = if (n > 0) acc / (zero * (n.toDouble() / frame)) else 0.0
                        if (norm > bestVal) {
                            bestVal = norm
                            bestLag = lag
                        }
                    }
                    if (bestLag > 0 && bestVal > 0.35) {
                        f0s.add(TARGET_RATE.toDouble() / bestLag)
                    }
                }
                // 谱重心 + 频带能量（Goertzel，免 FFT 依赖）。
                var magSum = 0.0
                var weighted = 0.0
                for (k in bandCenters.indices) {
                    val f = bandCenters[k]
                    val mag = goertzel(pcm, pos, frame, f)
                    magSum += mag
                    weighted += mag * f
                    bandEnergy[k] += mag
                }
                if (magSum > 1e-9) centroidSum += weighted / magSum
            }
            pos += hop
        }
        if (frames == 0) frames = 1
        f0s.sort()
        val f0Mean = if (f0s.isEmpty()) 0.0 else f0s[f0s.size / 2]
        var f0Var = 0.0
        if (f0s.isNotEmpty()) {
            for (v in f0s) f0Var += (v - f0Mean) * (v - f0Mean)
            f0Var /= f0s.size
        }
        val bandTotal = bandEnergy.sum().coerceAtLeast(1e-9)
        val emb = ArrayList<Double>(16)
        emb.add((f0Mean / 350.0).coerceIn(0.0, 1.0))
        emb.add((sqrt(f0Var) / 80.0).coerceIn(0.0, 1.0))
        emb.add((energySum / frames / 0.25).coerceIn(0.0, 1.0))
        emb.add((centroidSum / frames / 4000.0).coerceIn(0.0, 1.0))
        for (v in bandEnergy) emb.add((v / bandTotal).coerceIn(0.0, 1.0))
        emb.add((zcrSum / frames * 10).coerceIn(0.0, 1.0))
        emb.add((f0s.size.toDouble() / frames).coerceIn(0.0, 1.0))
        emb.add((pcm.size.toDouble() / TARGET_RATE / 30.0).coerceIn(0.0, 1.0))
        emb.add((frames.toDouble() / 1000.0).coerceIn(0.0, 1.0))

        return mapOf(
            "f0Mean" to f0Mean,
            "f0Std" to sqrt(f0Var),
            "energy" to (energySum / frames),
            "centroid" to (centroidSum / frames),
            "voicedRatio" to (f0s.size.toDouble() / frames),
            "embedding" to emb,
        )
    }

    private fun goertzel(x: FloatArray, offset: Int, n: Int, freq: Int): Double {
        val w = 2.0 * Math.PI * freq / TARGET_RATE
        val coeff = 2.0 * Math.cos(w)
        var s0 = 0.0
        var s1 = 0.0
        var s2 = 0.0
        for (i in 0 until n) {
            s0 = x[offset + i] + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        return sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2) / n
    }

    private fun writeWav(file: File, pcm: FloatArray, rate: Int) {
        val bytes = ByteArray(pcm.size * 2)
        for (i in pcm.indices) {
            val v = (pcm[i] * 32767).toInt().coerceIn(-32768, 32767)
            bytes[i * 2] = (v and 0xFF).toByte()
            bytes[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        val dataLen = bytes.size
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        header.putInt(36 + dataLen)
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(16)
        header.putShort(1) // PCM
        header.putShort(1) // mono
        header.putInt(rate)
        header.putInt(rate * 2)
        header.putShort(2)
        header.putShort(16)
        header.put("data".toByteArray())
        header.putInt(dataLen)
        FileOutputStream(file).use { out ->
            out.write(header.array())
            out.write(bytes)
        }
    }

    // ---------------- 选文件（SAF，不需要存储权限） ----------------

    private fun pickMedia(kind: String, result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("BUSY", "已有选择窗口在打开", null)
            return
        }
        pickResult = result
        // kind: audio / video / file（file 用于导入本机 GGUF 模型，不限类型）
        val mime = when (kind) {
            "video" -> "video/*"
            "file" -> "*/*"
            else -> "audio/*"
        }
        val title = when (kind) {
            "video" -> "选择视频"
            "file" -> "选择模型文件"
            else -> "选择音频"
        }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime
            }
            activity.startActivityForResult(
                Intent.createChooser(intent, title),
                REQ_PICK
            )
        } catch (e: Exception) {
            pickResult = null
            result.error("PICK_FAILED", e.message ?: "无法打开文件选择器", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQ_PICK) {
            val r = pickResult
            pickResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                r?.success(null)
                return true
            }
            val uri: Uri = data.data!!
            val path = copyToCache(uri)
            if (path == null) {
                r?.error("COPY_FAILED", "无法读取所选文件", null)
            } else {
                r?.success(
                    mapOf(
                        "path" to path,
                        "name" to displayName(uri),
                        "mime" to (activity.contentResolver.getType(uri) ?: ""),
                    )
                )
            }
            return true
        }
        if (requestCode == REQ_CREDENTIAL) {
            val r = credentialResult
            credentialResult = null
            r?.success(resultCode == Activity.RESULT_OK)
            return true
        }
        return false
    }

    private fun displayName(uri: Uri): String {
        return try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else "sample"
            } ?: "sample"
        } catch (_: Exception) {
            "sample"
        }
    }

    private fun copyToCache(uri: Uri): String? {
        return try {
            val dir = File(activity.cacheDir, "picked").apply { mkdirs() }
            val ext = displayName(uri).substringAfterLast('.', "bin")
            val out = File(dir, "pick_${System.currentTimeMillis()}.$ext")
            activity.contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            out.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    // ---------------- 语音识别 ----------------

    private fun sttStart(locale: String, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) {
            result.error("NO_PERMISSION", "缺少麦克风权限", null)
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.error("UNAVAILABLE", "该设备没有可用的语音识别服务", null)
            return
        }
        stopStt()
        try {
            val rec = SpeechRecognizer.createSpeechRecognizer(activity)
            rec.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    emit(mapOf("type" to "ready"))
                }
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {
                    emit(mapOf("type" to "rms", "value" to rmsdB))
                }
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {
                    emit(mapOf("type" to "end"))
                }
                override fun onError(error: Int) {
                    sttActive = false
                    emit(mapOf("type" to "error", "code" to error, "message" to sttError(error)))
                }
                override fun onResults(results: Bundle?) {
                    sttActive = false
                    val text = results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.joinToString(" ") ?: ""
                    emit(mapOf("type" to "final", "text" to text))
                }
                override fun onPartialResults(partialResults: Bundle?) {
                    val text = partialResults
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.joinToString(" ") ?: ""
                    if (text.isNotEmpty()) emit(mapOf("type" to "partial", "text" to text))
                }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                )
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                // 优先离线：本工程的隐私承诺要求语音不出设备。
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
            recognizer = rec
            sttActive = true
            rec.startListening(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("STT_FAILED", e.message ?: "识别启动失败", null)
        }
    }

    private fun stopStt() {
        try {
            recognizer?.stopListening()
            recognizer?.cancel()
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
        sttActive = false
    }

    private fun sttError(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_AUDIO -> "录音出错"
        SpeechRecognizer.ERROR_CLIENT -> "识别被中断"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "缺少麦克风权限"
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "需要网络或未安装离线语音包"
        SpeechRecognizer.ERROR_NO_MATCH -> "没听清，再说一次"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "识别忙，稍后再试"
        SpeechRecognizer.ERROR_SERVER -> "识别服务出错"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "没有检测到说话"
        else -> "识别失败"
    }

    private fun emit(event: Map<String, Any>) {
        main.post { sttSink?.success(event) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sttSink = events
    }

    override fun onCancel(arguments: Any?) {
        sttSink = null
    }

    // ---------------- 权限 ----------------

    private fun permOf(name: String): String? = when (name) {
        "microphone" -> Manifest.permission.RECORD_AUDIO
        "camera" -> Manifest.permission.CAMERA
        "notifications" ->
            if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null
        else -> null
    }

    private fun hasPermission(perm: String): Boolean =
        if (Build.VERSION.SDK_INT < 23) true
        else activity.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

    private fun permissionState(name: String): String {
        if (name == "overlay") {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                android.provider.Settings.canDrawOverlays(activity)
            ) "granted" else "denied"
        }
        val p = permOf(name) ?: return "unsupported"
        return if (hasPermission(p)) "granted" else "denied"
    }

    private fun requestPermission(name: String, result: MethodChannel.Result) {
        if (name == "overlay") {
            try {
                activity.startActivity(
                    Intent(
                        android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${activity.packageName}")
                    )
                )
            } catch (_: Exception) {
            }
            result.success(permissionState(name))
            return
        }
        val p = permOf(name)
        if (p == null) {
            result.success("unsupported")
            return
        }
        if (hasPermission(p)) {
            result.success("granted")
            return
        }
        if (Build.VERSION.SDK_INT < 23) {
            result.success("granted")
            return
        }
        permissionResult = result
        pendingPermission = p
        activity.requestPermissions(arrayOf(p), 2003)
    }

    /** 供 MainActivity 在 onRequestPermissionsResult 里回调。 */
    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != 2003) return
        val r = permissionResult
        permissionResult = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        r?.success(if (granted) "granted" else "denied")
        pendingPermission = null
    }

    // ---------------- 设备凭证（系统锁屏：PIN / 图案 / 指纹 / 人脸） ----------------

    private fun credentialAvailable(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
            val km = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            km.isDeviceSecure
        } catch (_: Exception) {
            false
        }
    }

    private fun authDeviceCredential(title: String, result: MethodChannel.Result) {
        val km = try {
            activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        } catch (_: Exception) {
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !km.isDeviceSecure) {
            result.success(false)
            return
        }
        val intent = try {
            km.createConfirmDeviceCredentialIntent(title, "验证后即可继续")
        } catch (_: Exception) {
            null
        }
        if (intent == null) {
            result.success(false)
            return
        }
        credentialResult = result
        try {
            activity.startActivityForResult(intent, REQ_CREDENTIAL)
        } catch (_: Exception) {
            credentialResult = null
            result.success(false)
        }
    }

    fun dispose() {
        // 在途的合成请求必须显式失败：Activity 销毁后监听器不会再回来，
        // 回调悬着会让 Dart 侧的那个 Future 永远不完成（UI 一直转圈）。
        pendingSynth.keys.toList().forEach { key ->
            pendingSynth.remove(key)?.first?.error("DISPOSED", "页面已关闭，合成已取消", null)
        }
        try {
            stopStt()
        } catch (_: Exception) {
        }
        stopPlay()
        releaseRecorder()
        try {
            tts?.shutdown()
        } catch (_: Exception) {
        }
        tts = null
    }
}
