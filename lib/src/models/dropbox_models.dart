// lib/models/dropbox_models.dart

part of '../../dropbox_native.dart';

/// Base error from Dropbox API responses (parsed from NativeResponse.data.error_summary or similar).
class DropboxError {
  final String? errorSummary;
  final String? errorType;
  final dynamic details;

  DropboxError({
    this.errorSummary,
    this.errorType,
    this.details,
  });

  factory DropboxError.fromJson(Map<String, dynamic> json) {
    return DropboxError(
      errorSummary: json['error_summary'] as String?,
      errorType: json['error']?['.tag'] as String?,
      details: json['error'],
    );
  }
}

/// Auth response (e.g., from StartAuthServer or ExchangeCodeForToken).
class AuthResponse {
  final String? accessToken;
  final String? refreshToken;
  final String? accountId;
  final List<String>? scopes;
  final DropboxError? error;

  AuthResponse({
    this.accessToken,
    this.refreshToken,
    this.accountId,
    this.scopes,
    this.error,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    if (json['error'] != null) {
      return AuthResponse(
        error: DropboxError.fromJson(json),
      );
    }
    return AuthResponse(
      accessToken: json['access_token'] as String?,
      refreshToken: json['refresh_token'] as String?,
      accountId: json['account_id'] as String?,
      scopes: (json['scope'] as String?)?.split(' '),
    );
  }

  factory AuthResponse.fromNativeResponse(NativeResponse response) {
    if (response.success && response.data != null) {
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    }
    return AuthResponse(
      error: response.error != null
          ? DropboxError(errorSummary: response.error)
          : null,
    );
  }
}

/// File or folder metadata (e.g., from GetMetadata).
class FileMetadata {
  final String? name;
  final String? pathLower;
  final String? pathDisplay;
  final int? size;
  final bool? isFolder;
  final String? id;
  final DropboxError? error;

  FileMetadata({
    this.name,
    this.pathLower,
    this.pathDisplay,
    this.size,
    this.isFolder,
    this.id,
    this.error,
  });

  factory FileMetadata.fromJson(Map<String, dynamic> json) {
    if (json['error'] != null) {
      return FileMetadata(
        error: DropboxError.fromJson(json),
      );
    }
    return FileMetadata(
      name: json['name'] as String?,
      pathLower: json['path_lower'] as String?,
      pathDisplay: json['path_display'] as String?,
      size: json['size'] as int?,
      isFolder: json['is_dir'] == true,
      id: json['id'] as String?,
    );
  }
}

/// Folder listing (e.g., from ListFolder).
class FolderListing {
  final List<FileMetadata> entries;
  final bool hasMore;
  final String? cursor;
  final DropboxError? error;

  FolderListing({
    required this.entries,
    required this.hasMore,
    this.cursor,
    this.error,
  });

  factory FolderListing.fromJson(Map<String, dynamic> json) {
    if (json['error'] != null) {
      return FolderListing(
        entries: [],
        hasMore: false,
        error: DropboxError.fromJson(json),
      );
    }
    final entriesJson = json['entries'] as List<dynamic>? ?? [];
    return FolderListing(
      entries: entriesJson
          .map((e) => FileMetadata.fromJson(e as Map<String, dynamic>))
          .toList(),
      hasMore: json['has_more'] == true,
      cursor: json['cursor'] as String?,
    );
  }

  factory FolderListing.fromNativeResponse(NativeResponse response) {
    if (response.success && response.data != null) {
      return FolderListing.fromJson(response.data as Map<String, dynamic>);
    }
    return FolderListing(
      entries: [],
      hasMore: false,
      error: response.error != null
          ? DropboxError(errorSummary: response.error)
          : null,
    );
  }
}

/// File request (e.g., from CreateFileRequest).
class FileRequest {
  final String? id;
  final String? title;
  final String? destination;
  final bool? isClosed;
  final DropboxError? error;

  FileRequest({
    this.id,
    this.title,
  this.destination,
    this.isClosed,
    this.error,
  });

  factory FileRequest.fromJson(Map<String, dynamic> json) {
    if (json['error'] != null) {
      return FileRequest(
        error: DropboxError.fromJson(json),
      );
    }
    return FileRequest(
      id: json['id'] as String?,
      title: json['title'] as String?,
      destination: json['destination'] as String?,
      isClosed: json['is_closed'] == true,
    );
  }
}

/// PKCE verifier/challenge/state (from GeneratePKCEVerifier, etc.).
class PKCEData {
  final String? verifier;
  final String? challenge;
  final String? state;

  PKCEData({
    this.verifier,
    this.challenge,
    this.state,
  });

  factory PKCEData.fromJson(Map<String, dynamic> json) {
    return PKCEData(
      verifier: json['verifier'] as String?,
      challenge: json['challenge'] as String?,
      state: json['state'] as String?,
    );
  }

  factory PKCEData.fromNativeResponse(NativeResponse response) {
    if (response.success && response.data != null) {
      return PKCEData.fromJson(response.data as Map<String, dynamic>);
    }
    return PKCEData();
  }
}

/// Enum for common Dropbox errors (extend as needed).
enum DropboxErrorType {
  rateLimit,
  authBad,
  pathNotFound,
  invalidArg,
  other;

  static DropboxErrorType fromString(String? tag) {
    switch (tag) {
      case 'rate_limit':
        return rateLimit;
      case 'auth_error':
      case 'auth_bad_state':
        return authBad;
      case 'path/not_found':
        return pathNotFound;
      case 'invalid_argument':
        return invalidArg;
      default:
        return other;
    }
  }
}