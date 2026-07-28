import 'dart:async';

import 'package:flutter/services.dart';

import 'settings_service.dart';

/// Applies reading-only display preferences to the current Android window.
/// The system brightness and timeout are restored as soon as a reader closes.
class ReadingDisplayService {
  static const _channel = MethodChannel('litra/reading_display');

  SettingsService? _settings;
  Timer? _batteryTimer;
  bool _active = false;

  Future<void> enter(SettingsService settings) async {
    if (_settings != settings) {
      _settings?.removeListener(_apply);
      _settings = settings..addListener(_apply);
    }
    _active = true;
    await _apply();
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(const Duration(minutes: 1), (_) => _apply());
  }

  Future<void> exit() async {
    _active = false;
    _batteryTimer?.cancel();
    _batteryTimer = null;
    await _restore();
  }

  Future<void> dispose() async {
    _settings?.removeListener(_apply);
    _settings = null;
    _batteryTimer?.cancel();
    await _restore();
  }

  Future<void> _apply() async {
    final settings = _settings;
    if (!_active || settings == null) return;
    try {
      await _channel.invokeMethod<void>('setBrightness', {
        'brightness': settings.readingBrightness,
      });
      final battery = await _channel.invokeMethod<int>('batteryPercent') ?? -1;
      final keepOn =
          settings.keepScreenOnWhileReading &&
          battery >= settings.keepScreenOnAboveBattery;
      await _channel.invokeMethod<void>('setKeepScreenOn', {'enabled': keepOn});
    } on PlatformException {
      // Reading must remain usable on platforms that do not expose a window
      // brightness override or a battery percentage through this channel.
    }
  }

  Future<void> _restore() async {
    try {
      await _channel.invokeMethod<void>('setBrightness', {'brightness': null});
      await _channel.invokeMethod<void>('setKeepScreenOn', {'enabled': false});
    } on PlatformException {
      // See _apply: display tuning is optional outside Android.
    }
  }
}
