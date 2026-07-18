package com.sukashiform.app

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ceil
import kotlin.math.roundToInt

class FrameExtractorApiImpl(
    private val progressApi: FrameExtractionProgressApi,
) : FrameExtractorApi {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cancellationFlags = ConcurrentHashMap<String, AtomicBoolean>()

    override fun probe(
        absoluteVideoPath: String,
        callback: (Result<VideoInfo>) -> Unit,
    ) {
        val info = runCatching { probeVideo(absoluteVideoPath) }
            .getOrElse { invalidInfo("metadata_unreadable") }
        callback(Result.success(info))
    }

    override fun generateThumbnail(
        absoluteVideoPath: String,
        absoluteOutputPath: String,
        maxLongEdgePx: Long,
        callback: (Result<String>) -> Unit,
    ) {
        callback(
            runCatching {
                require(maxLongEdgePx > 0L) { "maxLongEdgePx must be positive." }
                createThumbnail(
                    absoluteVideoPath,
                    absoluteOutputPath,
                    maxLongEdgePx.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                )
            },
        )
    }

    override fun extractFrames(
        taskId: String,
        request: ExtractRequest,
        callback: (Result<ExtractResult>) -> Unit,
    ) {
        val cancellationFlag = cancellationFlags.computeIfAbsent(taskId) {
            AtomicBoolean(false)
        }
        val result = runCatching {
            extractVideoFrames(taskId, request, cancellationFlag)
        }.getOrElse { error ->
            ExtractResult(
                isComplete = false,
                frameCount = 0L,
                sourceDurationMs = 0L,
                sourceFps = 0.0,
                errorReason = "extract_failed:${error.javaClass.simpleName}",
            )
        }
        cancellationFlags.remove(taskId, cancellationFlag)
        callback(Result.success(result))
    }

    override fun cancelExtraction(taskId: String) {
        cancellationFlags.computeIfAbsent(taskId) { AtomicBoolean(false) }.set(true)
    }

    private fun probeVideo(path: String): VideoInfo {
        val file = File(path)
        if (!file.isFile) {
            return invalidInfo("file_not_found")
        }
        if (file.length() == 0L) {
            return invalidInfo("empty_file")
        }

        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val duration = retriever.longMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            if (duration == null || duration <= 0L) {
                invalidInfo("invalid_duration")
            } else {
                VideoInfo(
                    isValid = true,
                    durationMs = duration,
                    width = retriever.longMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH) ?: 0L,
                    height = retriever.longMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT) ?: 0L,
                    rotationDegrees = retriever.longMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION),
                    errorReason = null,
                )
            }
        } catch (_: Exception) {
            invalidInfo("metadata_unreadable")
        } finally {
            retriever.release()
        }
    }

    private fun createThumbnail(
        videoPath: String,
        outputPath: String,
        maxLongEdgePx: Int,
    ): String {
        val source = File(videoPath)
        require(source.isFile && source.length() > 0L) { "Video file is missing or empty." }

        val retriever = MediaMetadataRetriever()
        var frame: Bitmap? = null
        var scaled: Bitmap? = null
        val output = File(outputPath)
        val temporary = File("$outputPath.tmp")
        try {
            retriever.setDataSource(videoPath)
            frame = retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: error("No video frame could be decoded.")
            scaled = scaleToLongEdge(frame, maxLongEdgePx)
            output.parentFile?.mkdirs()
            FileOutputStream(temporary).use { stream ->
                check(scaled.compress(Bitmap.CompressFormat.JPEG, 85, stream)) {
                    "JPEG compression failed."
                }
                stream.flush()
            }
            if (output.exists() && !output.delete()) {
                error("Existing thumbnail could not be replaced.")
            }
            check(temporary.renameTo(output)) { "Thumbnail could not be finalized." }
            return output.absolutePath
        } finally {
            if (temporary.exists()) {
                temporary.delete()
            }
            if (scaled != null && scaled !== frame) {
                scaled.recycle()
            }
            frame?.recycle()
            retriever.release()
        }
    }

    private fun extractVideoFrames(
        taskId: String,
        request: ExtractRequest,
        cancellationFlag: AtomicBoolean,
    ): ExtractResult {
        require(request.maxLongEdgePx > 0L) { "maxLongEdgePx must be positive." }
        require(request.maxFrames > 0L) { "maxFrames must be positive." }
        require(request.jpegQuality in 1L..100L) { "jpegQuality must be 1 through 100." }

        val source = File(request.absoluteVideoPath)
        if (!source.isFile || source.length() == 0L) {
            return extractionError("video_missing_or_empty")
        }

        val retriever = MediaMetadataRetriever()
        var completedFrames = 0
        var durationMs = 0L
        var sourceFps = 0.0
        try {
            retriever.setDataSource(request.absoluteVideoPath)
            durationMs = retriever.longMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?: return extractionError("invalid_duration")
            if (durationMs <= 0L) {
                return extractionError("invalid_duration")
            }
            val sourceFrameCount = retriever
                .longMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                ?.coerceAtMost(Int.MAX_VALUE.toLong())
                ?.toInt()
                ?: return extractionError("frame_count_unavailable", durationMs)
            if (sourceFrameCount <= 0) {
                return extractionError("frame_count_unavailable", durationMs)
            }

            sourceFps = sourceFrameCount.toDouble() / (durationMs.toDouble() / 1000.0)
            val rangeStartMs = request.rangeStartMs ?: 0L
            val requestedRangeEndMs = request.rangeEndMs
                ?: minOf(durationMs, rangeStartMs + MAX_EXTRACTION_DURATION_MS)
            require(rangeStartMs in 0 until durationMs) { "Invalid rangeStartMs." }
            require(requestedRangeEndMs in (rangeStartMs + 1)..durationMs) {
                "Invalid rangeEndMs."
            }
            val isWholeVideoPreview = request.maxFrames <= PREVIEW_MAX_FRAMES &&
                request.maxLongEdgePx <= PREVIEW_MAX_LONG_EDGE_PX
            val effectiveRangeEndMs = if (isWholeVideoPreview) {
                requestedRangeEndMs
            } else {
                minOf(requestedRangeEndMs, rangeStartMs + MAX_EXTRACTION_DURATION_MS)
            }
            val firstSourceIndex = (
                sourceFrameCount.toDouble() * rangeStartMs.toDouble() / durationMs.toDouble()
            ).toInt().coerceIn(0, sourceFrameCount - 1)
            val endSourceIndexExclusive = ceil(
                sourceFrameCount.toDouble() * effectiveRangeEndMs.toDouble() / durationMs.toDouble(),
            ).toInt().coerceIn(firstSourceIndex + 1, sourceFrameCount)
            val framesInWindow = endSourceIndexExclusive - firstSourceIndex
            val targetFrameCount = minOf(
                request.maxFrames.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                framesInWindow,
            )
            val sourceIndices = evenlySpacedIndices(framesInWindow, targetFrameCount)
                .map { index -> index + firstSourceIndex }
            val outputDirectory = File(request.absoluteOutputDir)
            outputDirectory.mkdirs()
            sendProgress(taskId, 0, targetFrameCount)
            for (batchStart in sourceIndices.indices step FRAME_BATCH_SIZE) {
                if (cancellationFlag.get()) {
                    return cancelledResult(completedFrames, durationMs, sourceFps)
                }
                val batchIndices = sourceIndices.subList(
                    batchStart,
                    minOf(batchStart + FRAME_BATCH_SIZE, sourceIndices.size),
                )
                if (isContiguous(batchIndices)) {
                    val bitmaps = retriever.getFramesAtIndex(
                        batchIndices.first(),
                        batchIndices.size,
                    ) ?: return extractionError(
                        "frame_decode_failed",
                        durationMs,
                        sourceFps,
                        completedFrames,
                    )
                    try {
                        if (bitmaps.size != batchIndices.size) {
                            return extractionError(
                                "frame_count_mismatch",
                                durationMs,
                                sourceFps,
                                completedFrames,
                            )
                        }
                        for (bitmap in bitmaps) {
                            if (cancellationFlag.get()) {
                                return cancelledResult(completedFrames, durationMs, sourceFps)
                            }
                            writeExtractedFrame(
                                bitmap,
                                outputDirectory,
                                completedFrames,
                                request.maxLongEdgePx.toInt(),
                                request.jpegQuality.toInt(),
                            )
                            completedFrames += 1
                        }
                    } finally {
                        bitmaps.forEach { bitmap ->
                            if (!bitmap.isRecycled) {
                                bitmap.recycle()
                            }
                        }
                    }
                } else {
                    for (sourceIndex in batchIndices) {
                        if (cancellationFlag.get()) {
                            return cancelledResult(completedFrames, durationMs, sourceFps)
                        }
                        val bitmap = retriever.getFrameAtIndex(sourceIndex)
                            ?: return extractionError(
                                "frame_decode_failed",
                                durationMs,
                                sourceFps,
                                completedFrames,
                            )
                        writeExtractedFrame(
                            bitmap,
                            outputDirectory,
                            completedFrames,
                            request.maxLongEdgePx.toInt(),
                            request.jpegQuality.toInt(),
                        )
                        completedFrames += 1
                    }
                }
                sendProgress(taskId, completedFrames, targetFrameCount)
            }

            val hasExplicitRange = request.rangeStartMs != null || request.rangeEndMs != null
            val isComplete = if (isWholeVideoPreview) {
                effectiveRangeEndMs == requestedRangeEndMs
            } else if (hasExplicitRange) {
                effectiveRangeEndMs == requestedRangeEndMs && framesInWindow <= request.maxFrames
            } else {
                durationMs <= MAX_EXTRACTION_DURATION_MS && sourceFrameCount <= request.maxFrames
            }
            return ExtractResult(
                isComplete = isComplete,
                frameCount = completedFrames.toLong(),
                sourceDurationMs = durationMs,
                sourceFps = sourceFps,
                errorReason = null,
            )
        } catch (error: Throwable) {
            return extractionError(
                "extract_failed:${error.javaClass.simpleName}",
                durationMs,
                sourceFps,
                completedFrames,
            )
        } finally {
            retriever.release()
        }
    }

    private fun evenlySpacedIndices(framesInWindow: Int, targetCount: Int): List<Int> {
        if (targetCount == 1) {
            return listOf(0)
        }
        return List(targetCount) { outputIndex ->
            (
                outputIndex.toDouble() * (framesInWindow - 1).toDouble() /
                    (targetCount - 1).toDouble()
            ).roundToInt()
        }
    }

    private fun isContiguous(indices: List<Int>): Boolean {
        return indices.zipWithNext().all { (first, second) -> second == first + 1 }
    }

    private fun writeExtractedFrame(
        source: Bitmap,
        outputDirectory: File,
        outputIndex: Int,
        maxLongEdgePx: Int,
        jpegQuality: Int,
    ) {
        var scaled: Bitmap = source
        try {
            // MediaMetadataRetriever applies METADATA_KEY_VIDEO_ROTATION while
            // creating the Bitmap. Rotating it again here would turn portrait
            // recordings sideways.
            scaled = scaleToLongEdge(source, maxLongEdgePx)
            val name = String.format(Locale.US, "frame_%06d.jpg", outputIndex)
            writeJpegAtomically(scaled, File(outputDirectory, name), jpegQuality)
        } finally {
            if (scaled !== source && !scaled.isRecycled) {
                scaled.recycle()
            }
            if (!source.isRecycled) {
                source.recycle()
            }
        }
    }

    private fun writeJpegAtomically(bitmap: Bitmap, output: File, jpegQuality: Int) {
        val temporary = File("${output.path}.tmp")
        try {
            FileOutputStream(temporary).use { stream ->
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, stream)) {
                    "JPEG compression failed."
                }
                stream.flush()
            }
            if (output.exists() && !output.delete()) {
                error("Existing frame could not be replaced.")
            }
            check(temporary.renameTo(output)) { "Frame could not be finalized." }
        } finally {
            if (temporary.exists()) {
                temporary.delete()
            }
        }
    }

    private fun sendProgress(taskId: String, completedFrames: Int, totalFrames: Int) {
        mainHandler.post {
            progressApi.onProgress(
                taskId,
                completedFrames.toLong(),
                totalFrames.toLong(),
            ) { }
        }
    }

    private fun cancelledResult(
        completedFrames: Int,
        durationMs: Long,
        sourceFps: Double,
    ) = ExtractResult(
        isComplete = false,
        frameCount = completedFrames.toLong(),
        sourceDurationMs = durationMs,
        sourceFps = sourceFps,
        errorReason = "cancelled",
    )

    private fun extractionError(
        reason: String,
        durationMs: Long = 0L,
        sourceFps: Double = 0.0,
        completedFrames: Int = 0,
    ) = ExtractResult(
        isComplete = false,
        frameCount = completedFrames.toLong(),
        sourceDurationMs = durationMs,
        sourceFps = sourceFps,
        errorReason = reason,
    )

    private fun scaleToLongEdge(source: Bitmap, maxLongEdgePx: Int): Bitmap {
        val longEdge = maxOf(source.width, source.height)
        if (longEdge <= maxLongEdgePx) {
            return source
        }
        val scale = maxLongEdgePx.toDouble() / longEdge.toDouble()
        val width = (source.width * scale).roundToInt().coerceAtLeast(1)
        val height = (source.height * scale).roundToInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    private fun MediaMetadataRetriever.longMetadata(key: Int): Long? =
        extractMetadata(key)?.toLongOrNull()

    private fun invalidInfo(reason: String) = VideoInfo(
        isValid = false,
        durationMs = 0L,
        width = 0L,
        height = 0L,
        rotationDegrees = null,
        errorReason = reason,
    )

    private companion object {
        const val FRAME_BATCH_SIZE = 8
        const val MAX_EXTRACTION_DURATION_MS = 10_000L
        const val PREVIEW_MAX_FRAMES = 24L
        const val PREVIEW_MAX_LONG_EDGE_PX = 240L
    }
}
