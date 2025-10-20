library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'generated_bindings.dart'; // Your FFI binding file

part 'src/services/dropbox_service.dart';
part 'src/models/dropbox_models.dart';
part 'src/models/native_response.dart';

/// Main entry point for the Dropbox Native library wrapper.
/// Provides a simple API for OAuth authentication and file operations using the Go FFI binding.
///
/// Usage Example:
/// ```dart
/// final dropbox = DropboxNative('your-client-id', 'your-client-secret');
/// await dropbox.initialize(); // Sets up service and event listeners
///
/// // Start OAuth flow
/// final authData = await dropbox.startOAuthFlow();
/// // Open authData['auth_url'] in WebView
/// // Handle redirect to get authorization code
/// 
/// // Complete auth with code from redirect
/// final auth = await dropbox.handleOAuthCallback(
///   state: authData['state'],
///   code: 'auth-code-from-redirect'
/// );
/// 
/// if (auth.accessToken != null) {
///   print('Access token: ${auth.accessToken}');
///   // Now use account ID for file operations
///   final listing = await dropbox.listFolder(auth.accountId!, '/');
///   print('Files: ${listing.entries.map((e) => e.name).toList()}');
/// }
///
/// dropbox.dispose(); // Cleanup
/// ```
class DropboxNative {
  final String clientId;
  final String clientSecret;

  late final DropboxService service;
  String? _currentAccountId;

  String get _clientId => clientId;
  String get _clientSecret => clientSecret;

  /// Creates a new instance with client credentials.
  /// Does not initialize the native library—call [initialize] for that.
  DropboxNative(this.clientId, this.clientSecret) : service = DropboxService();

  /// Gets the current authenticated account ID
  String? get currentAccountId => _currentAccountId;

  /// Initializes the native library, sets up the service, and event listeners.
  /// Must be called before any auth or file operations.
  Future<void> initialize() async {
    await service.init();

    // Listen to events (e.g., progress updates, errors from native)
    service.events.listen((event) {
      if (event.op == 'download_progress' || event.op == 'upload_progress') {
        // Progress events are handled by individual task streams
      } else if (!event.success) {
        print('Error event: ${event.op} - ${event.error}');
      }
    });
  }

  /// Starts the OAuth flow and returns authorization URL and state
  /// 
  /// Returns a map containing:
  /// - 'auth_url': The URL to open in a browser/WebView
  /// - 'state': The state parameter for security validation
  /// - 'client_id': Your Dropbox app client ID
  /// - 'client_secret': Your Dropbox app client secret
  Future<Map<String, dynamic>> startOAuthFlow({int port = 0}) async {
    if (!_clientId.isNotEmpty || !_clientSecret.isNotEmpty) {
      throw ArgumentError('Client ID and secret must be provided');
    }

    final authData = await service.startOAuthFlow(
      _clientId,
      _clientSecret,
      port: port,
    );

    return authData;
  }

  /// Handles OAuth callback with authorization code and state
  /// 
  /// [state]: The state parameter returned from startOAuthFlow
  /// [code]: The authorization code from the redirect URL
  /// 
  /// Returns [AuthResponse] with access token, refresh token, and account info
  Future<AuthResponse> handleOAuthCallback({
    required String state,
    required String code,
    int port = 0,
  }) async {
    final authResponse = await service.handleOAuthCallback(
      state,
      code,
      _clientId,
      _clientSecret,
      port: port,
    );

    if (authResponse.accessToken != null) {
      _currentAccountId = authResponse.accountId;
    }

    if (authResponse.error != null) {
      throw Exception('OAuth failed: ${authResponse.error!.errorSummary}');
    }

    return authResponse;
  }

  /// Refreshes an access token for the given account
  Future<AuthResponse> refreshToken(String accountId, {int port = 0}) async {
    final authResponse = await service.refreshToken(
      accountId,
      _clientId,
      _clientSecret,
      port: port,
    );

    if (authResponse.error != null) {
      throw Exception('Token refresh failed: ${authResponse.error!.errorSummary}');
    }

    return authResponse;
  }

  // ---- File Operations ----

  /// Lists folder contents
  /// 
  /// [accountId]: The Dropbox account ID (from auth response)
  /// [path]: The folder path to list (use '/' for root)
  Future<FolderListing> listFolder(String accountId, String path, {int port = 0}) async {
    return await service.listFolder(accountId, path, port: port);
  }

  /// Downloads a file with progress tracking
  /// 
  /// Returns a task ID that can be used to track progress and cancel the operation
  /// 
  /// Use [watchDownloadProgress] to monitor progress and [waitForDownloadCompletion] 
  /// to wait for completion
  Future<int> downloadFile({
    required String accountId,
    required String remotePath,
    required String localPath,
    int port = 0,
  }) async {
    return await service.downloadFile(
      accountId,
      remotePath,
      localPath,
      port: port,
    );
  }

  /// Uploads a file with progress tracking
  /// 
  /// Returns a task ID that can be used to track progress and cancel the operation
  /// 
  /// Use [watchUploadProgress] to monitor progress and [waitForUploadCompletion] 
  /// to wait for completion
  Future<int> uploadFile({
    required String accountId,
    required String localPath,
    required String remotePath,
    int port = 0,
  }) async {
    return await service.uploadFile(
      accountId,
      localPath,
      remotePath,
      port: port,
    );
  }

  /// Gets metadata for a file or folder
  Future<FileMetadata> getFileMetadata(String accountId, String path, {int port = 0}) async {
    return await service.getFileMetadata(accountId, path, port: port);
  }

  // ---- File Request Operations ----

  /// Lists all file requests for an account
  Future<List<FileRequest>> listFileRequests(String accountId, {int port = 0}) async {
    return await service.listFileRequests(accountId, port: port);
  }

  /// Creates a new file request
  Future<FileRequest> createFileRequest({
    required String accountId,
    required String title,
    required String destination,
    int port = 0,
  }) async {
    return await service.createFileRequest(
      accountId,
      title,
      destination,
      port: port,
    );
  }

  // ---- Progress Tracking ----

  /// Watches download progress for a task
  Stream<Map<String, dynamic>> watchDownloadProgress(int taskId) {
    return service.watchDownloadProgress(taskId);
  }

  /// Watches upload progress for a task
  Stream<Map<String, dynamic>> watchUploadProgress(int taskId) {
    return service.watchUploadProgress(taskId);
  }

  /// Waits for download completion and returns result
  Future<Map<String, dynamic>> waitForDownloadCompletion(int taskId) async {
    return await service.waitForDownloadCompletion(taskId);
  }

  /// Waits for upload completion and returns result
  Future<Map<String, dynamic>> waitForUploadCompletion(int taskId) async {
    return await service.waitForUploadCompletion(taskId);
  }

  // ---- Task Management ----

  /// Stops a running task (download/upload)
  Future<void> stopTask(int taskId, {int port = 0}) async {
    await service.stopTask(taskId, port: port);
  }

  // ---- Account Management ----

  /// Logs out an account and clears local tokens
  Future<void> logoutAccount(String accountId, {int port = 0}) async {
    await service.logoutAccount(accountId, port: port);
    if (_currentAccountId == accountId) {
      _currentAccountId = null;
    }
  }

  /// Cleans up all resources and tokens
  Future<void> cleanupAll({int port = 0}) async {
    await service.cleanupAll(port: port);
    _currentAccountId = null;
  }

  /// Cleans up resources (unregisters port, closes streams)
  void dispose() {
    service.dispose();
  }
}

// Example usage class for common operations
class DropboxManager {
  final DropboxNative _dropbox;
  final Map<int, StreamSubscription> _progressSubscriptions = {};

  DropboxManager(String clientId, String clientSecret)
      : _dropbox = DropboxNative(clientId, clientSecret);

  Future<void> initialize() async {
    await _dropbox.initialize();
  }

  /// Complete OAuth flow with WebView integration
  Future<AuthResponse> performOAuthFlow({
    required Future<void> Function(String authUrl) launchWebView,
    required Future<String> Function() waitForRedirect,
  }) async {
    // Start OAuth flow
    final authData = await _dropbox.startOAuthFlow();
    final authUrl = authData['auth_url'] as String;
    final state = authData['state'] as String;

    // Launch WebView
    await launchWebView(authUrl);

    // Wait for redirect and extract code
    final redirectUrl = await waitForRedirect();
    final uri = Uri.parse(redirectUrl);
    final code = uri.queryParameters['code'];

    if (code == null) {
      throw Exception('No authorization code found in redirect');
    }

    // Complete OAuth
    return await _dropbox.handleOAuthCallback(state: state, code: code);
  }

  /// Download file with progress callbacks
  Future<void> downloadFileWithProgress({
    required String accountId,
    required String remotePath,
    required String localPath,
    required void Function(double progress) onProgress,
    required void Function(Map<String, dynamic> result) onComplete,
    required void Function(Exception error) onError,
  }) async {
    try {
      final taskId = await _dropbox.downloadFile(
        accountId: accountId,
        remotePath: remotePath,
        localPath: localPath,
      );

      // Listen for progress
      _progressSubscriptions[taskId] = _dropbox
          .watchDownloadProgress(taskId)
          .listen((progress) => onProgress(progress['progress'] as double));

      // Wait for completion
      final result = await _dropbox.waitForDownloadCompletion(taskId);
      _progressSubscriptions.remove(taskId)?.cancel();
      onComplete(result);
    } catch (e) {
      onError(e as Exception);
    }
  }

  /// Upload file with progress callbacks
  Future<void> uploadFileWithProgress({
    required String accountId,
    required String localPath,
    required String remotePath,
    required void Function(double progress) onProgress,
    required void Function(Map<String, dynamic> result) onComplete,
    required void Function(Exception error) onError,
  }) async {
    try {
      final taskId = await _dropbox.uploadFile(
        accountId: accountId,
        localPath: localPath,
        remotePath: remotePath,
      );

      // Listen for progress
      _progressSubscriptions[taskId] = _dropbox
          .watchUploadProgress(taskId)
          .listen((progress) => onProgress(progress['progress'] as double));

      // Wait for completion
      final result = await _dropbox.waitForUploadCompletion(taskId);
      _progressSubscriptions.remove(taskId)?.cancel();
      onComplete(result);
    } catch (e) {
      onError(e as Exception);
    }
  }

  /// Cancel all running operations
  void cancelAllOperations() {
    for (final subscription in _progressSubscriptions.values) {
      subscription.cancel();
    }
    _progressSubscriptions.clear();
  }

  void dispose() {
    cancelAllOperations();
    _dropbox.dispose();
  }
}

// Re-export parts for easy imports in consuming code
