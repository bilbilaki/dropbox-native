// lib/models/native_response.dart
part of '../../dropbox_native.dart';
class NativeResponse {
  final String? op;
  final bool success;
  final String? error;
  final dynamic data;

  NativeResponse({
    this.op,
    required this.success,
    this.error,
    this.data,
  });

  /// Parse a message that can be either JSON or a plain string.
  factory NativeResponse.fromMessage(dynamic raw) {
    if (raw == null) {
      return NativeResponse(
        op: null,
        success: false,
        error: 'null message',
        data: null,
      );
    }

    String msg;
    if (raw is String) {
      msg = raw;
    } else if (raw is List<int>) {
      msg = String.fromCharCodes(raw);
    } else {
      msg = raw.toString();
    }

    // Try to decode JSON; if it fails, treat as plain text response
    try {
      final decoded = json.decode(msg);
      if (decoded is String) {
        return NativeResponse(op: null, success: true, data: decoded);
      }
      return NativeResponse(
        op: decoded['op'] as String?,
        success: decoded['success'] == true,
        error: decoded['error'] as String?,
        data: decoded['data'],
      );
    } catch (_) {
      // Plain string => success with data being the string
      return NativeResponse(op: null, success: true, data: msg);
    }
  }

  @override
  String toString() =>
      'NativeResponse(op: $op, success: $success, error: $error, data: $data)';
}