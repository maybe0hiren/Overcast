import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Desktop VideoPlayerPlatform implementation:
/// - On Linux: uses the native GStreamer FlPixelBufferTexture channel (`overcast/video_player`)
///   for hardware/software decoded in-app video playback with full scrubbing, volume, and speed control.
/// - On Windows (or if GStreamer is unavailable): falls back gracefully or launches external media player.
class OvercastDesktopVideoPlayerPlatform extends VideoPlayerPlatform {
  static const MethodChannel _channel = MethodChannel('overcast/video_player');
  static int? _lastActivePlayerId;

  static void registerIfNeeded() {
    if (Platform.isLinux || Platform.isWindows) {
      VideoPlayerPlatform.instance = OvercastDesktopVideoPlayerPlatform();
    }
  }

  /// Queries the native GStreamer pipeline for the latest media duration.
  static Future<Duration?> queryNativeDuration() async {
    final playerId = _lastActivePlayerId;
    if (!Platform.isLinux || playerId == null || playerId < 0) return null;
    try {
      final int? durMs = await _channel.invokeMethod<int>(
        'duration',
        <String, dynamic>{'textureId': playerId},
      );
      if (durMs != null && durMs > 0) {
        return Duration(milliseconds: durMs);
      }
    } catch (_) {}
    return null;
  }

  /// Seeks the active native GStreamer pipeline directly.
  static Future<void> seekNative(Duration position) async {
    final playerId = _lastActivePlayerId;
    if (!Platform.isLinux || playerId == null || playerId < 0) return;
    try {
      await _channel.invokeMethod<void>('seekTo', <String, dynamic>{
        'textureId': playerId,
        'position': position.inMilliseconds,
      });
    } catch (_) {}
  }

  @override
  Future<void> init() async {
    if (Platform.isLinux) {
      try {
        await _channel.invokeMethod<void>('init');
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose(int playerId) async {
    if (Platform.isLinux) {
      await _channel.invokeMethod<void>('dispose', <String, dynamic>{
        'textureId': playerId,
      });
    }
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    String? uri = dataSource.uri;
    if (uri == null || uri.isEmpty) {
      throw PlatformException(
        code: 'InvalidDataSource',
        message: 'Video URI is empty',
      );
    }

    if (Platform.isLinux) {
      final Map<dynamic, dynamic>? response =
          await _channel.invokeMapMethod<dynamic, dynamic>(
        'create',
        <String, dynamic>{'uri': uri},
      );
      final int? texId = response?['textureId'] as int?;
      _lastActivePlayerId = texId;
      return texId;
    }

    throw PlatformException(
      code: 'DesktopExternalPlayer',
      message:
          'Inline video decoding uses system media player on this desktop platform.',
    );
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) {
    return create(options.dataSource);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return EventChannel('overcast/video_player/events/$playerId')
        .receiveBroadcastStream()
        .map((dynamic event) {
      final Map<dynamic, dynamic> map = event as Map<dynamic, dynamic>;
      final String? type = map['event'] as String?;
      switch (type) {
        case 'initialized':
          final int durationMs = (map['duration'] as num?)?.toInt() ?? 0;
          final double width = (map['width'] as num?)?.toDouble() ?? 1280.0;
          final double height = (map['height'] as num?)?.toDouble() ?? 720.0;
          return VideoEvent(
            eventType: VideoEventType.initialized,
            duration: Duration(milliseconds: durationMs),
            size: Size(width, height),
          );
        case 'durationUpdate':
          final int durMs = (map['duration'] as num?)?.toInt() ?? 0;
          return VideoEvent(
            eventType: VideoEventType.bufferingUpdate,
            buffered: <DurationRange>[
              DurationRange(Duration.zero, Duration(milliseconds: durMs)),
            ],
          );
        case 'completed':
          return VideoEvent(eventType: VideoEventType.completed);
        case 'bufferingStart':
          return VideoEvent(eventType: VideoEventType.bufferingStart);
        case 'bufferingEnd':
          return VideoEvent(eventType: VideoEventType.bufferingEnd);
        default:
          return VideoEvent(eventType: VideoEventType.unknown);
      }
    });
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    if (Platform.isLinux) {
      await _channel.invokeMethod<void>('setLooping', <String, dynamic>{
        'textureId': playerId,
        'looping': looping,
      });
    }
  }

  @override
  Future<void> play(int playerId) async {
    if (Platform.isLinux) {
      await _channel.invokeMethod<void>('play', <String, dynamic>{
        'textureId': playerId,
      });
    }
  }

  @override
  Future<void> pause(int playerId) async {
    if (Platform.isLinux) {
      await _channel.invokeMethod<void>('pause', <String, dynamic>{
        'textureId': playerId,
      });
    }
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    if (Platform.isLinux) {
      await _channel.invokeMethod<void>('setVolume', <String, dynamic>{
        'textureId': playerId,
        'volume': volume,
      });
    }
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    if (Platform.isLinux) {
      await _channel.invokeMethod<void>('setPlaybackSpeed', <String, dynamic>{
        'textureId': playerId,
        'speed': speed,
      });
    }
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    if (Platform.isLinux) {
      await _channel.invokeMethod<void>('seekTo', <String, dynamic>{
        'textureId': playerId,
        'position': position.inMilliseconds,
      });
    }
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    if (Platform.isLinux) {
      final int? posMs = await _channel.invokeMethod<int>(
        'position',
        <String, dynamic>{'textureId': playerId},
      );
      return Duration(milliseconds: posMs ?? 0);
    }
    return Duration.zero;
  }

  @override
  Widget buildView(int playerId) {
    return Texture(textureId: playerId);
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    return Texture(textureId: options.playerId);
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  /// Opens a stream URL in the best available external desktop media player
  /// (VLC, mpv, ffplay, or OS default handler).
  static Future<bool> openInExternalPlayer(String streamUrl) async {
    if (Platform.isLinux) {
      for (final bin in const ['vlc', 'mpv', 'celluloid', 'totem', 'ffplay', 'xdg-open']) {
        try {
          final whichRes = await Process.run('which', [bin]);
          if (whichRes.exitCode == 0) {
            await Process.start(
              bin,
              [streamUrl],
              mode: ProcessStartMode.detached,
            );
            return true;
          }
        } catch (_) {}
      }
    } else if (Platform.isWindows) {
      try {
        await Process.start(
          'cmd',
          ['/c', 'start', '', streamUrl],
          mode: ProcessStartMode.detached,
        );
        return true;
      } catch (_) {}
    }

    final uri = Uri.tryParse(streamUrl);
    if (uri != null) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }
}
