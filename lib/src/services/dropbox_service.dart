// lib/services/dropbox_service.dart
part of '../../dropbox_native.dart';

class DropboxService {
  static final DropboxService _instance = DropboxService._internal();
  factory DropboxService() => _instance;
  DropboxService._internal();

  late final ffi.DynamicLibrary _dylib;
  late final libdropbox _native;

  ReceivePort? _receivePort;
  int? _nativePort;

  // Pending completers keyed by op string. FIFO queue to match responses.
  final Map<String, Queue<Completer<NativeResponse>>> _pending = {};

  // Unsolicited events broadcast (e.g., auth callbacks, errors).
  final StreamController<NativeResponse> _eventsController =
      StreamController.broadcast();
  Stream<NativeResponse> get events => _eventsController.stream;

  bool _initialized = false;

  // Default timeout for waiting a response from native.
  Duration responseTimeout = const Duration(seconds: 6);

  /// Initialize and load the native library.
  /// libPath defaults to platform-specific (adjust for your bundling).
  Future<void> init({String? libPath}) async {
    if (_initialized) return;

    // Platform-specific lib path (extend for iOS/macOS/Windows).
    libPath ??= _getDefaultLibPath();

    _dylib = ffi.DynamicLibrary.open(libPath);
    _native = libdropbox(_dylib);

    // Initialize Dart API table in native side.
    _native.BridgeInit(ffi.NativeApi.initializeApiDLData);

    // Create receive port and listen.
    _receivePort = ReceivePort();
    _receivePort!.listen(_handleNativeMessage);
    _nativePort = _receivePort!.sendPort.nativePort;

    // Register the port in native side.
    _native.RegisterPort(_nativePort!);

    _initialized = true;
  }

  String _getDefaultLibPath() {
    // Example: Adjust based on platform (use dart:io for runtime detection in Flutter).
    if (Platform.isAndroid) return 'native/android/libdropbox.so';
    if (Platform.isIOS) return 'native/ios/libdropbox.dylib';
    if (Platform.isMacOS) return 'native/macos/libdropbox.dylib';
    if (Platform.isLinux) return 'native/linux/libdropbox.so';
    if (Platform.isWindows) return 'native/windows/libdropbox.dll';
    throw UnsupportedError('Platform not supported');
  }

  /// Cleanup and unregister port.
  void dispose() {
    if (!_initialized) return;
    try {
      _native.UnregisterPort();
    } catch (_) {}
    _receivePort?.close();
    _eventsController.close();
    _initialized = false;
  }

  void _handleNativeMessage(dynamic raw) {
    final resp = NativeResponse.fromMessage(raw);

    bool tryCompleteByKey(String key) {
      final q = _pending[key];
      if (q != null && q.isNotEmpty) {
        final c = _pending[key]!.removeFirst();
        if (_pending[key]!.isEmpty) _pending.remove(key);
        if (!c.isCompleted) c.complete(resp);
        return true;
      }
      return false;
    }

    // Try normal JSON op-based completion.
    final op = resp.op;
    if (op != null && op.isNotEmpty) {
      if (tryCompleteByKey(op)) return;
    } else if (resp.data is String) {
      // Fallback: Try plain string ack (exact or prefix match).
      final s = resp.data as String;
      if (tryCompleteByKey(s)) return;
      for (final key in _pending.keys.toList()) {
        if (s.startsWith(key)) {
          if (tryCompleteByKey(key)) return;
        }
      }
    }

    // Unsolicited event (e.g., auth redirect or error).
    _eventsController.add(resp);
  }

  // Internal: Call native function and wait for op response.
  Future<NativeResponse> _callAndWait(String op, void Function() call) {
    final completer = Completer<NativeResponse>();
    _pending.putIfAbsent(op, () => Queue<Completer<NativeResponse>>()).add(completer);
    try {
      call();
    } catch (e) {
      // Remove from queue on error.
      final q = _pending[op];
      if (q != null) {
        q.removeWhere((c) => c == completer);
        if (q.isEmpty) _pending.remove(op);
      }
      completer.completeError(e);
      return completer.future;
    }
    return completer.future.timeout(
      responseTimeout,
      onTimeout: () {
        // Remove from queue on timeout.
        final q = _pending[op];
        if (q != null) {
          q.removeWhere((c) => c == completer);
          if (q.isEmpty) _pending.remove(op);
        }
        throw TimeoutException('Timeout waiting for op=$op', responseTimeout);
      },
    );
  }

  // High-level wrappers (all async, await NativeResponse or typed models).
  // Assume op = function name in camelCase (e.g., 'startAuthServer').

  /// Start the OAuth auth server.
  Future<NativeResponse> startAuthServer(
    String clientId,
    String clientSecret, {
    int port = 0,
  }) {
    final idPtr = clientId.toNativeUtf8();
    final secretPtr = clientSecret.toNativeUtf8();
    return _callAndWait('startAuthServer', () {
      try {
        _native.StartAuthServer(idPtr.cast(), secretPtr.cast(), port);
      } finally {
        calloc.free(idPtr);
        calloc.free(secretPtr);
      }
    });
  }

  /// Exchange code for token (PKCE flow).
  Future<AuthResponse> exchangeCodeForToken(
    String clientId,
    String clientSecret,
    String code,
    String verifier, {
    int port = 0,
  }) async {
    final idPtr = clientId.toNativeUtf8();
    final secretPtr = clientSecret.toNativeUtf8();
    final codePtr = code.toNativeUtf8();
    final verifierPtr = verifier.toNativeUtf8();
    final response = await _callAndWait('exchangeCodeForToken', () {
      try {
        _native.ExchangeCodeForToken(
          idPtr.cast(),
          secretPtr.cast(),
          codePtr.cast(),
          verifierPtr.cast(),
          port,
        );
      } finally {
        calloc.free(idPtr);
        calloc.free(secretPtr);
        calloc.free(codePtr);
        calloc.free(verifierPtr);
      }
    });
    return AuthResponse.fromNativeResponse(response);
  }

  /// Refresh access token.
  Future<AuthResponse> refreshToken(
    String clientId,
    String clientSecret,
    String refreshToken, {
    int port = 0,
  }) async {
    final idPtr = clientId.toNativeUtf8();
    final secretPtr = clientSecret.toNativeUtf8();
    final tokenPtr = refreshToken.toNativeUtf8();
    final response = await _callAndWait('refreshToken', () {
      try {
        _native.RefreshToken(idPtr.cast(), secretPtr.cast(), tokenPtr.cast(), port);
      } finally {
        calloc.free(idPtr);
        calloc.free(secretPtr);
        calloc.free(tokenPtr);
      }
    });
    return AuthResponse.fromNativeResponse(response);
  }

  /// Count file requests.
  Future<NativeResponse> countFileRequests(
    String accessToken, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    return _callAndWait('countFileRequests', () {
      try {
        _native.CountFileRequests(tokenPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
      }
    });
  }

  /// Create a file request.
  Future<FileRequest> createFileRequest(
    String accessToken,
    Map<String, dynamic> args, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final argsJson = json.encode(args);
    final argsPtr = argsJson.toNativeUtf8();
    final response = await _callAndWait('createFileRequest', () {
      try {
        _native.CreateFileRequest(tokenPtr.cast(), argsPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(argsPtr);
      }
    });
    // Assume data is FileRequest JSON.
    if (response.success && response.data != null) {
      return FileRequest.fromJson(response.data as Map<String, dynamic>);
    }
    return FileRequest(
      error: response.error != null ? DropboxError(errorSummary: response.error) : null,
    );
  }

  /// Delete file requests.
  Future<NativeResponse> deleteFileRequests(
    String accessToken,
    Map<String, dynamic> args, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    final argsJson = json.encode(args);
    final argsPtr = argsJson.toNativeUtf8();
    return _callAndWait('deleteFileRequests', () {
      try {
        _native.DeleteFileRequests(tokenPtr.cast(), argsPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(argsPtr);
      }
    });
  }

  /// Delete all closed file requests.
  Future<NativeResponse> deleteAllClosedFileRequests(
    String accessToken, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    return _callAndWait('deleteAllClosedFileRequests', () {
      try {
        _native.DeleteAllClosedFileRequests(tokenPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
      }
    });
  }

  /// Get a file request by ID.
  Future<FileRequest> getFileRequest(
    String accessToken,
    String id, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final idPtr = id.toNativeUtf8();
    final response = await _callAndWait('getFileRequest', () {
      try {
        _native.GetFileRequest(tokenPtr.cast(), idPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(idPtr);
      }
    });
    if (response.success && response.data != null) {
      return FileRequest.fromJson(response.data as Map<String, dynamic>);
    }
    return FileRequest(
      error: response.error != null ? DropboxError(errorSummary: response.error) : null,
    );
  }

  /// List file requests.
  Future<NativeResponse> listFileRequests(
    String accessToken,
    Map<String, dynamic> args, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    final argsJson = json.encode(args);
    final argsPtr = argsJson.toNativeUtf8();
    return _callAndWait('listFileRequests', () {
      try {
        _native.ListFileRequests(tokenPtr.cast(), argsPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(argsPtr);
      }
    });
  }

  /// Continue listing file requests.
  Future<NativeResponse> listFileRequestsContinue(
    String accessToken,
    String cursor, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    final cursorPtr = cursor.toNativeUtf8();
    return _callAndWait('listFileRequestsContinue', () {
      try {
        _native.ListFileRequestsContinue(tokenPtr.cast(), cursorPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(cursorPtr);
      }
    });
  }

  /// Update a file request.
  Future<NativeResponse> updateFileRequest(
    String accessToken,
    Map<String, dynamic> args, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    final argsJson = json.encode(args);
    final argsPtr = argsJson.toNativeUtf8();
    return _callAndWait('updateFileRequest', () {
      try {
        _native.UpdateFileRequest(tokenPtr.cast(), argsPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(argsPtr);
      }
    });
  }

  /// List folder contents.
  Future<FolderListing> listFolder(
    String accessToken,
    Map<String, dynamic> args, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final argsJson = json.encode(args);
    final argsPtr = argsJson.toNativeUtf8();
    final response = await _callAndWait('listFolder', () {
      try {
        _native.ListFolder(tokenPtr.cast(), argsPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(argsPtr);
      }
    });
    return FolderListing.fromNativeResponse(response);
  }

  /// Continue listing folder.
  Future<FolderListing> listFolderContinue(
    String accessToken,
    String cursor, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final cursorPtr = cursor.toNativeUtf8();
    final response = await _callAndWait('listFolderContinue', () {
      try {
        _native.ListFolderContinue(tokenPtr.cast(), cursorPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(cursorPtr);
      }
    });
    return FolderListing.fromNativeResponse(response);
  }

  /// Create a folder.
  Future<FileMetadata> createFolder(
    String accessToken,
    String path, {
    bool autorename = false,
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final pathPtr = path.toNativeUtf8();
    final response = await _callAndWait('createFolder', () {
      try {
        _native.CreateFolder(tokenPtr.cast(), pathPtr.cast(), autorename ? 1 : 0, port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(pathPtr);
      }
    });
    if (response.success && response.data != null) {
      return FileMetadata.fromJson(response.data as Map<String, dynamic>);
    }
    return FileMetadata(
      error: response.error != null ? DropboxError(errorSummary: response.error) : null,
    );
  }

  /// Delete a file.
  Future<NativeResponse> deleteFile(
    String accessToken,
    String path, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    final pathPtr = path.toNativeUtf8();
    return _callAndWait('deleteFile', () {
      try {
        _native.DeleteFile(tokenPtr.cast(), pathPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(pathPtr);
      }
    });
  }

  /// Get metadata for a file/folder.
  Future<FileMetadata> getMetadata(
    String accessToken,
    String path, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final pathPtr = path.toNativeUtf8();
    final response = await _callAndWait('getMetadata', () {
      try {
        _native.GetMetadata(tokenPtr.cast(), pathPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(pathPtr);
      }
    });
    if (response.success && response.data != null) {
      return FileMetadata.fromJson(response.data as Map<String, dynamic>);
    }
    return FileMetadata(
      error: response.error != null ? DropboxError(errorSummary: response.error) : null,
    );
  }

  /// Download a file (data in response.data as base64 or URL).
  Future<NativeResponse> downloadFile(
    String accessToken,
    String path, {
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    final pathPtr = path.toNativeUtf8();
    return _callAndWait('downloadFile', () {
      try {
        _native.DownloadFile(tokenPtr.cast(), pathPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(pathPtr);
      }
    });
  }

  /// Upload a file (dataB64 is base64-encoded file content).
  Future<FileMetadata> uploadFile(
    String accessToken,
    Map<String, dynamic> args,
    String dataB64, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final argsJson = json.encode(args);
    final argsPtr = argsJson.toNativeUtf8();
    final dataPtr = dataB64.toNativeUtf8();
    final response = await _callAndWait('uploadFile', () {
      try {
        _native.UploadFile(tokenPtr.cast(), argsPtr.cast(), dataPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(argsPtr);
        calloc.free(dataPtr);
      }
    });
    if (response.success && response.data != null) {
      return FileMetadata.fromJson(response.data as Map<String, dynamic>);
    }
    return FileMetadata(
      error: response.error != null ? DropboxError(errorSummary: response.error) : null,
    );
  }

  /// Copy a file.
  Future<FileMetadata> copyFile(
    String accessToken,
    String fromPath,
    String toPath, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final fromPtr = fromPath.toNativeUtf8();
    final toPtr = toPath.toNativeUtf8();
    final response = await _callAndWait('copyFile', () {
      try {
        _native.CopyFile(tokenPtr.cast(), fromPtr.cast(), toPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(fromPtr);
        calloc.free(toPtr);
      }
    });
    if (response.success && response.data != null) {
      return FileMetadata.fromJson(response.data as Map<String, dynamic>);
    }
    return FileMetadata(
      error: response.error != null ? DropboxError(errorSummary: response.error) : null,
    );
  }

  /// Move a file.
  Future<FileMetadata> moveFile(
    String accessToken,
    String fromPath,
    String toPath, {
    int port = 0,
  }) async {
    final tokenPtr = accessToken.toNativeUtf8();
    final fromPtr = fromPath.toNativeUtf8();
    final toPtr = toPath.toNativeUtf8();
    final response = await _callAndWait('moveFile', () {
      try {
        _native.MoveFile(tokenPtr.cast(), fromPtr.cast(), toPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(fromPtr);
        calloc.free(toPtr);
      }
    });
    if (response.success && response.data != null) {
      return FileMetadata.fromJson(response.data as Map<String, dynamic>);
    }
    return FileMetadata(
      error: response.error != null ? DropboxError(errorSummary: response.error) : null,
    );
  }

  /// Search files/folders (V2).
  Future<NativeResponse> searchV2(
    String accessToken,
    String query, {
    Map<String, dynamic>? options,
    int port = 0,
  }) {
    final tokenPtr = accessToken.toNativeUtf8();
    final queryPtr = query.toNativeUtf8();
    final optionsJson = options != null ? json.encode(options) : '';
    final optionsPtr = optionsJson.toNativeUtf8();
    return _callAndWait('searchV2', () {
      try {
        _native.SearchV2(tokenPtr.cast(), queryPtr.cast(), optionsPtr.cast(), port);
      } finally {
        calloc.free(tokenPtr);
        calloc.free(queryPtr);
        calloc.free(optionsPtr);
      }
    });
  }

  /// Get available scopes.
  Future<List<String>> getScopes({int port = 0}) async {
    final response = await _callAndWait('getScopes', () => _native.GetScopes(port));
    if (response.success && response.data != null) {
      final scopesJson = response.data as List<dynamic>? ?? [];
      return scopesJson.map((s) => s as String).toList();
    }
    throw Exception('Failed to get scopes: ${response.error}');
  }

  /// Get redirect URI for auth.
  Future<String> getRedirectUri({int port = 0}) async {
    final response = await _callAndWait('getRedirectURI', () => _native.GetRedirectURI(port));
    if (response.success && response.data is String) {
      return response.data as String;
    }
    throw Exception('Failed to get redirect URI: ${response.error}');
  }

  /// Generate PKCE verifier.
  Future<PKCEData> generatePKCEVerifier({int port = 0}) async {
    final response = await _callAndWait('generatePKCEVerifier', () => _native.GeneratePKCEVerifier(port));
    return PKCEData.fromNativeResponse(response);
  }

  /// Generate PKCE challenge from verifier.
  Future<PKCEData> generatePKCEChallenge(
    String verifier, {
    int port = 0,
  }) async {
    final verifierPtr = verifier.toNativeUtf8();
    final response = await _callAndWait('generatePKCEChallenge', () {
      try {
        _native.GeneratePKCEChallenge(verifierPtr.cast(), port);
      } finally {
        calloc.free(verifierPtr);
      }
    });
    return PKCEData.fromNativeResponse(response);
  }

  /// Generate random state for auth.
  Future<String> generateState({int port = 0}) async {
    final response = await _callAndWait('generateState', () => _native.GenerateState(port));
    if (response.success && response.data is String) {
      return response.data as String;
    }
    throw Exception('Failed to generate state: ${response.error}');
  }

  /// Stop a task (e.g., ongoing upload/download).
  Future<NativeResponse> stopTask(
    int taskId, {
    int port = 0,
  }) {
    return _callAndWait('stopTask', () => _native.StopTask(taskId, port));
  }

  /// Get library version.
  Future<String> getLibraryVersion({int port = 0}) async {
    final response = await _callAndWait('getLibraryVersion', () => _native.GetLibraryVersion(port));
    if (response.success && response.data is String) {
      return response.data as String;
    }
    throw Exception('Failed to get version: ${response.error}');
  }

  /// Get API endpoints.
  Future<NativeResponse> getEndpoints({int port = 0}) {
    return _callAndWait('getEndpoints', () => _native.GetEndpoints(port));
  }
}