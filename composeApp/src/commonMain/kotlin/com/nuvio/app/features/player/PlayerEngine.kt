package com.nuvio.app.features.player

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

interface PlayerEngineController {
    val playbackEngine: AndroidPlaybackEngine? get() = null
    fun play()
    fun pause()
    fun seekTo(positionMs: Long)
    fun seekBy(offsetMs: Long)
    fun retry()
    fun isPictureInPictureSupported(): Boolean = false
    fun startPictureInPicture() {}
    fun showCastDialog() {}
    fun setPlaybackSpeed(speed: Float)
    fun currentPlayerVolume(): PlayerAudioLevel = PlayerAudioLevel(
        fraction = 1f,
        isMuted = false,
    )
    fun setPlayerVolume(level: Float): PlayerAudioLevel = PlayerAudioLevel(
        fraction = 1f,
        isMuted = false,
    )
    fun setMuted(muted: Boolean) {}
    fun getAudioTracks(): List<AudioTrack>
    fun getSubtitleTracks(): List<SubtitleTrack>
    fun applyAudioLanguagePreferences(languages: List<String>)
    fun selectAudioTrack(index: Int)
    fun selectSubtitleTrack(index: Int)
    fun setSubtitleUri(url: String)
    fun clearExternalSubtitle()
    fun clearExternalSubtitleAndSelect(trackIndex: Int)
    fun applySubtitleStyle(style: SubtitleStyleState) {}
    fun applySubtitlePreferences(
        preferredLanguage: String,
        secondaryPreferredLanguage: String? = null,
        useForcedSubtitles: Boolean,
        autoSelectionApplied: Boolean,
        hasActiveSubtitle: Boolean,
        useCustomSubtitles: Boolean = false,
    ) {}
    /**
     * Enables or disables hardware-keyboard shortcuts that a platform handles outside Compose
     * (currently only iOS/mpv). Disabled while an overlay owns the keyboard or the controls
     * are locked.
     */
    fun setKeyboardShortcutsEnabled(enabled: Boolean) {}

    /**
     * Routes a shortcut the platform recognised back into the player runtime, so a key press
     * takes exactly the same path as the equivalent tap or gesture.
     */
    fun setKeyboardShortcutHandler(handler: ((PlayerKeyboardShortcut) -> Unit)?) {}
    fun setSubtitleDelayMs(delayMs: Int) {}
    fun configureIosVideoOutput(settings: PlayerSettingsUiState) {}
    fun updateNowPlayingMetadata(info: PlayerNowPlayingInfo) {}
    fun clearNowPlayingInfo() {}
    suspend fun getMediaInfo(): PlayerMediaInfo = PlayerMediaInfo()
}

internal fun sanitizePlaybackHeaders(headers: Map<String, String>?): Map<String, String> {
    val rawHeaders = headers ?: return emptyMap()
    if (rawHeaders.isEmpty()) return emptyMap()

    val sanitized = LinkedHashMap<String, String>(rawHeaders.size)
    rawHeaders.forEach { (rawKey, rawValue) ->
        val key = rawKey.trim()
        val value = rawValue.trim()
        if (key.isEmpty() || value.isEmpty()) return@forEach
        if (key.equals("Range", ignoreCase = true)) return@forEach
        sanitized[key] = value
    }
    return sanitized
}

internal fun sanitizePlaybackResponseHeaders(headers: Map<String, String>?): Map<String, String> {
    val rawHeaders = headers ?: return emptyMap()
    if (rawHeaders.isEmpty()) return emptyMap()

    val sanitized = LinkedHashMap<String, String>(rawHeaders.size)
    rawHeaders.forEach { (rawKey, rawValue) ->
        val key = rawKey.trim()
        val value = rawValue.trim()
        if (key.isEmpty() || value.isEmpty()) return@forEach
        sanitized[key] = value
    }
    return sanitized
}

@Composable
expect fun PlatformPlayerSurface(
    sourceUrl: String,
    sourceAudioUrl: String? = null,
    sourceHeaders: Map<String, String> = emptyMap(),
    sourceResponseHeaders: Map<String, String> = emptyMap(),
    externalSubtitles: List<com.nuvio.app.features.streams.StreamSubtitle> = emptyList(),
    streamType: String? = null,
    useYoutubeChunkedPlayback: Boolean = false,
    modifier: Modifier = Modifier,
    playWhenReady: Boolean = true,
    initialPositionMs: Long? = null,
    initialPositionRequestKey: String? = null,
    resizeMode: PlayerResizeMode = PlayerResizeMode.Fit,
    playbackEngine: AndroidPlaybackEngine? = null,
    useNativeController: Boolean = false,
    onInitialPositionHandled: (key: String, handled: Boolean) -> Unit = { _, _ -> },
    onControllerReady: (PlayerEngineController) -> Unit,
    onSnapshot: (PlayerPlaybackSnapshot) -> Unit,
    onError: (String?) -> Unit,
)

/**
 * Hosts the player's playback logic: track and source effects, switching to the next episode, and (where
 * [playerSurfaceInLogicHost]) the player surface. On iOS, Compose stops recomposing while the app is in the
 * background, e.g. with the iPad locked and video on a connected display, so [content] runs in its own
 * composition there and must not emit UI. Elsewhere it runs in place.
 */
@Composable
expect fun PlaybackLogicHost(content: @Composable () -> Unit)

/** Whether the player surface belongs in [PlaybackLogicHost], its video then shown by [PlaybackVideo]. */
expect val playerSurfaceInLogicHost: Boolean

/** Shows the video of the player surface inside [PlaybackLogicHost]. */
@Composable
expect fun PlaybackVideo(modifier: Modifier)
