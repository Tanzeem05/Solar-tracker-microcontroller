import 'package:flutter/services.dart';

abstract interface class AlertService {
  Future<bool> enabled();
  Future<bool> requestPermission();
  Future<bool> show({
    required int id,
    required String title,
    required String body,
  });
}

class AndroidAlertService implements AlertService {
  static const _channel = MethodChannel('solar_tracker/alerts');
  @override
  Future<bool> enabled() async =>
      await _channel.invokeMethod<bool>('enabled') ?? false;
  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;
  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
  }) async =>
      await _channel.invokeMethod<bool>('show', {
        'id': id,
        'title': title,
        'body': body,
      }) ??
      false;
}
