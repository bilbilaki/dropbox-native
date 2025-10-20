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
/// // Handle auth redirect (e.g., via WebView) to get 'auth-code-from-redirect'
/// final auth = await dropbox.performAuthFlow('auth-code-from-redirect');
/// if (auth.accessToken != null) {
///   print('Access token: ${auth.accessToken}');
///   // Now use token for file ops, e.g.:
///   final listing = await dropbox.listFolder(auth.accessToken!, {'path': ''});
///   print('Files: ${listing.entries.map((e) => e.name).toList()}');
/// }
///
/// dropbox.dispose(); // Cleanup
/// ```
/// 
class DropboxNative {
  final String clientId;
  final String clientSecret;

  late final DropboxService service;
String get _clientId => clientId;
String get _clientSecret => clientSecret;

  /// Creates a new instance with client credentials.
  /// Does not initialize the native library—call [initialize] for that.
  DropboxNative(this.clientId, this.clientSecret) : service = DropboxService();

  /// Initializes the native library, sets up the service, and event listeners.
  /// Must be called before any auth or file operations.
  Future<void> initialize() async {
    await service.init(); // Pass port if needed for native

    // Listen to events (e.g., auth success or errors from native).
    service.events.listen((event) {
      if (event.op == 'authSuccess') {
        print('Auth event: ${event.data}'); // Handle as needed (e.g., notify UI)
      } else if (event.op == 'authError') {
        print('Auth error: ${event.error}');
      }
      // Add more event handlers as needed (e.g., for upload progress).
    });
  }

  /// Performs the full OAuth PKCE flow:
  /// 1. Generates PKCE verifier, challenge, state, and redirect URI.
  /// 2. Starts the auth server.
  /// 3. Exchanges the provided [authCode] (from redirect) for tokens.
  ///
  /// Call this after handling the auth redirect (e.g., in a WebView) to get the code.
  /// Returns the [AuthResponse] with access/refresh tokens.
  Future<AuthResponse> performAuthFlow(String authCode, {int port = 0}) async {
    if (!_clientId.isNotEmpty || !_clientSecret.isNotEmpty) {
      throw ArgumentError('Client ID and secret must be provided');
    }

    // Step 1: Generate PKCE and state.
    final pkceData = await service.generatePKCEVerifier(port: port);
    if (pkceData.verifier == null) {
      throw Exception('Failed to generate PKCE verifier');
    }

    final challengeData = await service.generatePKCEChallenge(pkceData.verifier!, port: port);
    if (challengeData.challenge == null) {
      throw Exception('Failed to generate PKCE challenge');
    }

    final state = await service.generateState(port: port);
    final redirectUri = await service.getRedirectUri(port: port);

    print('Auth URL: https://www.dropbox.com/oauth2/authorize?client_id=$_clientId&redirect_uri=$redirectUri&response_type=code&code_challenge=${challengeData.challenge}&code_challenge_method=S256&state=$state');
    // TODO: Open this URL in a WebView or browser (use url_launcher package).
    // Extract 'authCode' from the redirect URI query params.

    // Step 2: Start auth server (native handles callback if port is listening).
    await service.startAuthServer(_clientId, _clientSecret, port: port);

    // Step 3: Exchange code for token.
    final authResponse = await service.exchangeCodeForToken(
      _clientId,
      _clientSecret,
      authCode,
      pkceData.verifier!,
      port: port,
    );

    if (authResponse.error != null) {
      throw Exception('Auth failed: ${authResponse.error!.errorSummary}');
    }

    return authResponse;
  }

  /// Refreshes an access token using the refresh token.
  Future<AuthResponse> refreshAccessToken(String refreshToken, {int port = 0}) async {
    return await service.refreshToken(_clientId, _clientSecret, refreshToken, port: port);
  }

  // Delegate file operations to service (add more as needed).
  // Examples:

  /// Lists files in a folder.
  Future<FolderListing> listFolder(String accessToken, Map<String, dynamic> args, {int port = 0}) async {
    return await service.listFolder(accessToken, args, port: port);
  }

  /// Gets metadata for a file or folder.
  Future<FileMetadata> getMetadata(String accessToken, String path, {int port = 0}) async {
    return await service.getMetadata(accessToken, path, port: port);
  }

  /// Uploads a file (args include path, etc.; dataB64 is base64-encoded content).
  Future<FileMetadata> uploadFile(String accessToken, Map<String, dynamic> args, String dataB64, {int port = 0}) async {
    return await service.uploadFile(accessToken, args, dataB64, port: port);
  }

  /// Downloads a file (returns NativeResponse with data, e.g., base64 or URL).
  Future<NativeResponse> downloadFile(String accessToken, String path, {int port = 0}) async {
    return await service.downloadFile(accessToken, path, port: port);
  }

  // Add more delegations (createFolder, deleteFile, etc.) as needed...

  /// Cleans up resources (unregisters port, closes streams).
  void dispose() {
    service.dispose();
  }
}

// Re-export parts for easy imports in consuming code.
