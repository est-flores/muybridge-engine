import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Playback state emitted on [MuybridgeController.onStateChanged].
enum MuybridgePlayerState {
  idle,
  loading,
  buffering,
  ready,
  playing,
  paused,
  ended,
  error,
}

MuybridgePlayerState _stateFromString(String s) {
  switch (s) {
    case 'loading':
      return MuybridgePlayerState.loading;
    case 'buffering':
      return MuybridgePlayerState.buffering;
    case 'ready':
      return MuybridgePlayerState.ready;
    case 'playing':
      return MuybridgePlayerState.playing;
    case 'paused':
      return MuybridgePlayerState.paused;
    case 'ended':
      return MuybridgePlayerState.ended;
    case 'error':
      return MuybridgePlayerState.error;
    default:
      return MuybridgePlayerState.idle;
  }
}

/// Controls a Muybridge video player instance.
///
/// Usage:
/// ```dart
/// final controller = MuybridgeController();
/// await controller.initialize();
/// await controller.load('https://example.com/video.mp4');
/// controller.play();
/// // ...
/// controller.dispose();
/// ```
class MuybridgeController {
  static const _methodChannel = MethodChannel('muybridge_flutter/player');

  static int _nextPlayerId = 1;

  final int _playerId = _nextPlayerId++;

  int _textureId = -1;

  /// The Flutter texture ID. Pass this to [Texture] widget.
  /// Returns -1 before [initialize] completes.
  int get textureId => _textureId;

  final StreamController<MuybridgePlayerState> _stateController =
      StreamController<MuybridgePlayerState>.broadcast();

  /// Stream of player state changes.
  Stream<MuybridgePlayerState> get onStateChanged => _stateController.stream;

  EventChannel? _eventChannel;
  StreamSubscription? _eventSub;

  /// Initialize the native player and register a Flutter texture.
  /// Must be called before any other method.
  Future<void> initialize() async {
    final result = await _methodChannel.invokeMapMethod<String, dynamic>(
      'initialize',
      {'id': _playerId},
    );
    _textureId = result!['textureId'] as int;

    _eventChannel =
        EventChannel('muybridge_flutter/player/$_playerId/events');
    _eventSub = _eventChannel!.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final stateStr = event['state'] as String?;
        if (stateStr != null) {
          _stateController.add(_stateFromString(stateStr));
        }
      }
    });
  }

  /// Load media from [url]. Returns true on success.
  /// Resolves when the native decoder has opened the media.
  Future<bool> load(String url) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'load',
      {'id': _playerId, 'url': url},
    );
    return result ?? false;
  }

  /// Start playback.
  void play() {
    _methodChannel.invokeMethod<void>('play', {'id': _playerId});
  }

  /// Pause playback.
  void pause() {
    _methodChannel.invokeMethod<void>('pause', {'id': _playerId});
  }

  /// Seek to [position].
  void seek(Duration position) {
    _methodChannel.invokeMethod<void>('seek', {
      'id': _playerId,
      'positionNanos': position.inMicroseconds * 1000,
    });
  }

  /// Release all resources.
  void dispose() {
    _eventSub?.cancel();
    _stateController.close();
    _methodChannel.invokeMethod<void>('dispose', {'id': _playerId});
  }
}

/// Renders the video for a [MuybridgeController].
///
/// Pass [controller] after calling [MuybridgeController.initialize].
class MuybridgeVideoPlayer extends StatelessWidget {
  final MuybridgeController controller;

  const MuybridgeVideoPlayer({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    if (controller.textureId < 0) return const SizedBox.shrink();
    return Texture(textureId: controller.textureId);
  }
}
