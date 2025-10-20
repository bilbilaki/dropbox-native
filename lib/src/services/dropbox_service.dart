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

  // Pending completers keyed by op string
  final Map<String, Queue<Completer<NativeResponse>>> _pending = {};

  // Stream for progress updates and unsolicited events
  final StreamController<NativeResponse> _eventsController =
      StreamController.broadcast();
  Stream<NativeResponse> get events => _eventsController.stream;

  bool _initialized = false;
  Duration responseTimeout = const Duration(seconds: 30);

  /// Initialize and load the native library
  Future<void> init({String? libPath}) async {
    if (_initialized) return;

    libPath ??= _getDefaultLibPath();
    _dylib = ffi.DynamicLibrary.open(libPath);
    _native = libdropbox(_dylib);

    // Initialize Dart API
    _native.BridgeInit(ffi.NativeApi.initializeApiDLData);

    // Create receive port and listen
    _receivePort = ReceivePort();
    _receivePort!.listen(_handleNativeMessage);
    _nativePort = _receivePort!.sendPort.nativePort;

    // Register the port
    _native.RegisterPort(_nativePort!);

    _initialized = true;
  }

  String _getDefaultLibPath() {
    if (Platform.isAndroid) return '/native/android/libdropbox.so';
    if (Platform.isIOS) return '/native/ios/libdropbox.dylib';
    if (Platform.isMacOS) return '/native/mac/libdropbox.dylib';
    if (Platform.isLinux) return '/native/linux/libdropbox.so';
    if (Platform.isWindows) return '/native/windows/dropbox.dll';
    throw UnsupportedError('Platform not supported');
  }

  /// Cleanup and unregister port
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

    // Handle progress updates and unsolicited events
    if (resp.op == 'download_progress' || resp.op == 'upload_progress') {
      _eventsController.add(resp);
      return;
    }

    // Try to complete pending operations
    bool tryCompleteByKey(String key) {
      final q = _pending[key];
      if (q != null && q.isNotEmpty) {
        final c = q.removeFirst();
        if (q.isEmpty) _pending.remove(key);
        if (!c.isCompleted) c.complete(resp);
        return true;
      }
      return false;
    }

    final op = resp.op;
    if (op != null && op.isNotEmpty) {
      if (tryCompleteByKey(op)) return;
    }

    // Unsolicited event
    _eventsController.add(resp);
  }

  Future<NativeResponse> _callAndWait(String op, void Function() call) {
    if (!_initialized) {
      throw Exception('DropboxService not initialized. Call init() first.');
    }

    final completer = Completer<NativeResponse>();
    _pending.putIfAbsent(op, () => Queue<Completer<NativeResponse>>()).add(completer);
    
    try {
      call();
    } catch (e) {
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
        final q = _pending[op];
        if (q != null) {
          q.removeWhere((c) => c == completer);
          if (q.isEmpty) _pending.remove(op);
        }
        throw TimeoutException('Timeout waiting for op=$op', responseTimeout);
      },
    );
  }

  // ---- OAuth Methods ----

  /// Start OAuth flow and get authorization URL
  Future<Map<String, dynamic>> startOAuthFlow(
    String clientId,
    String clientSecret, {
    int port = 0,
  }) async {
    final idPtr = clientId.toNativeUtf8();
    final secretPtr = clientSecret.toNativeUtf8();
    
    final response = await _callAndWait('start_oauth_flow', () {
      try {
        _native.StartOAuthFlow(idPtr.cast(), secretPtr.cast(), port);
      } finally {
        calloc.free(idPtr);
        calloc.free(secretPtr);
      }
    });

    if (response.success && response.data != null) {
      return response.data as Map<String, dynamic>;
    }
    throw Exception('Failed to start OAuth flow: ${response.error}');
  }

  /// Handle OAuth callback with authorization code
  Future<AuthResponse> handleOAuthCallback(
    String state,
    String code,
    String clientId,
    String clientSecret, {
    int port = 0,
  }) async {
    final statePtr = state.toNativeUtf8();
    final codePtr = code.toNativeUtf8();
    final idPtr = clientId.toNativeUtf8();
    final secretPtr = clientSecret.toNativeUtf8();

    final response = await _callAndWait('handle_oauth_callback', () {
      try {
        _native.HandleOAuthCallback(
          statePtr.cast(),
          codePtr.cast(),
          idPtr.cast(),
          secretPtr.cast(),
          port,
        );
      } finally {
        calloc.free(statePtr);
        calloc.free(codePtr);
        calloc.free(idPtr);
        calloc.free(secretPtr);
      }
    });

    return AuthResponse.fromNativeResponse(response);
  }

  /// Refresh access token
  Future<AuthResponse> refreshToken(
    String accountId,
    String clientId,
    String clientSecret, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();
    final idPtr = clientId.toNativeUtf8();
    final secretPtr = clientSecret.toNativeUtf8();

    final response = await _callAndWait('refresh_token', () {
      try {
        _native.RefreshToken(
          accountPtr.cast(),
          idPtr.cast(),
          secretPtr.cast(),
          port,
        );
      } finally {
        calloc.free(accountPtr);
        calloc.free(idPtr);
        calloc.free(secretPtr);
      }
    });

    return AuthResponse.fromNativeResponse(response);
  }

  // ---- File Operations ----

  /// List folder contents
  Future<FolderListing> listFolder(
    String accountId,
    String path, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();
    final pathPtr = path.toNativeUtf8();

    final response = await _callAndWait('list_folder', () {
      try {
        _native.ListFolder(accountPtr.cast(), pathPtr.cast(), port);
      } finally {
        calloc.free(accountPtr);
        calloc.free(pathPtr);
      }
    });

    return FolderListing.fromNativeResponse(response);
  }

  /// Download file with progress tracking
  Future<int> downloadFile(
    String accountId,
    String remotePath,
    String localPath, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();
    final remotePtr = remotePath.toNativeUtf8();
    final localPtr = localPath.toNativeUtf8();

    // This returns a task ID immediately
    final taskId = _native.DownloadFile(
      accountPtr.cast(),
      remotePtr.cast(),
      localPtr.cast(),
      port,
    );

    calloc.free(accountPtr);
    calloc.free(remotePtr);
    calloc.free(localPtr);

    return taskId;
  }

  /// Upload file with progress tracking
  Future<int> uploadFile(
    String accountId,
    String localPath,
    String remotePath, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();
    final localPtr = localPath.toNativeUtf8();
    final remotePtr = remotePath.toNativeUtf8();

    // This returns a task ID immediately
    final taskId = _native.UploadFile(
      accountPtr.cast(),
      localPtr.cast(),
      remotePtr.cast(),
      port,
    );

    calloc.free(accountPtr);
    calloc.free(localPtr);
    calloc.free(remotePtr);

    return taskId;
  }

  /// Get file metadata
  Future<FileMetadata> getFileMetadata(
    String accountId,
    String path, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();
    final pathPtr = path.toNativeUtf8();

    final response = await _callAndWait('get_file_metadata', () {
      try {
        _native.GetFileMetadata(accountPtr.cast(), pathPtr.cast(), port);
      } finally {
        calloc.free(accountPtr);
        calloc.free(pathPtr);
      }
    });

    if (response.success && response.data != null) {
      return FileMetadata.fromJson(response.data as Map<String, dynamic>);
    }
    return FileMetadata(
      error: response.error != null 
          ? DropboxError(errorSummary: response.error)
          : null,
    );
  }

  // ---- File Request Operations ----

  /// List file requests
  Future<List<FileRequest>> listFileRequests(
    String accountId, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();

    final response = await _callAndWait('list_file_requests', () {
      try {
        _native.ListFileRequests(accountPtr.cast(), port);
      } finally {
        calloc.free(accountPtr);
      }
    });

    if (response.success && response.data != null) {
      final data = response.data as Map<String, dynamic>;
      final requests = data['file_requests'] as List<dynamic>? ?? [];
      return requests
          .map((r) => FileRequest.fromJson(r as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to list file requests: ${response.error}');
  }

  /// Create file request
  Future<FileRequest> createFileRequest(
    String accountId,
    String title,
    String destination, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();
    final titlePtr = title.toNativeUtf8();
    final destPtr = destination.toNativeUtf8();

    final response = await _callAndWait('create_file_request', () {
      try {
        _native.CreateFileRequest(
          accountPtr.cast(),
          titlePtr.cast(),
          destPtr.cast(),
          port,
        );
      } finally {
        calloc.free(accountPtr);
        calloc.free(titlePtr);
        calloc.free(destPtr);
      }
    });

    if (response.success && response.data != null) {
      return FileRequest.fromJson(response.data as Map<String, dynamic>);
    }
    return FileRequest(
      error: response.error != null 
          ? DropboxError(errorSummary: response.error)
          : null,
    );
  }

  // ---- Task Management ----

  /// Stop a running task (download/upload)
  Future<void> stopTask(
    int taskId, {
    int port = 0,
  }) async {
    final response = await _callAndWait('stop', () {
      _native.StopTask(taskId, port);
    });

    if (!response.success) {
      throw Exception('Failed to stop task: ${response.error}');
    }
  }

  // ---- Account Management ----

  /// Logout account and clear tokens
  Future<void> logoutAccount(
    String accountId, {
    int port = 0,
  }) async {
    final accountPtr = accountId.toNativeUtf8();

    final response = await _callAndWait('logout_account', () {
      try {
        _native.LogoutAccount(accountPtr.cast(), port);
      } finally {
        calloc.free(accountPtr);
      }
    });

    if (!response.success) {
      throw Exception('Failed to logout account: ${response.error}');
    }
  }

  /// Cleanup all resources
  Future<void> cleanupAll({
    int port = 0,
  }) async {
    final response = await _callAndWait('cleanup_all', () {
      _native.CleanupAll(port);
    });

    if (!response.success) {
      throw Exception('Failed to cleanup: ${response.error}');
    }
  }

  // ---- Helper Methods ----

  /// Listen for download progress
  Stream<Map<String, dynamic>> watchDownloadProgress(int taskId) {
    return events
        .where((response) =>
            response.op == 'download_progress' &&
            response.data is Map &&
            (response.data as Map)['task_id'] == taskId)
        .map((response) => response.data as Map<String, dynamic>);
  }

  /// Listen for upload progress  
  Stream<Map<String, dynamic>> watchUploadProgress(int taskId) {
    return events
        .where((response) =>
            response.op == 'upload_progress' &&
            response.data is Map &&
            (response.data as Map)['task_id'] == taskId)
        .map((response) => response.data as Map<String, dynamic>);
  }

  /// Wait for download completion
  Future<Map<String, dynamic>> waitForDownloadCompletion(int taskId) async {
    final response = await events.firstWhere((response) =>
        response.op == 'download_file' &&
        response.data is Map &&
        (response.data as Map)['task_id'] == taskId);
    
    if (!response.success) {
      throw Exception('Download failed: ${response.error}');
    }
    return response.data as Map<String, dynamic>;
  }

  /// Wait for upload completion
  Future<Map<String, dynamic>> waitForUploadCompletion(int taskId) async {
    final response = await events.firstWhere((response) =>
        response.op == 'upload_file' &&
        response.data is Map &&
        (response.data as Map)['task_id'] == taskId);
    
    if (!response.success) {
      throw Exception('Upload failed: ${response.error}');
    }
    return response.data as Map<String, dynamic>;
  }
}