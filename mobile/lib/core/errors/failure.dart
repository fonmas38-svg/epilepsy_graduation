import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_client.dart';
import '../theme/risk_view.dart';

/// The only error taxonomy the UI is allowed to know about.
///
/// `docs/frontend-plan-ar.md` §2.6 forbids showing a raw technical message to a
/// patient. Instead every thrown object is funnelled through [Failure.from] into
/// one of these kinds, and each kind has exactly one user-facing sentence in
/// [AppLocalizations]. The technical text survives in [Failure.debugDetail] for
/// logs, and never reaches the screen.
enum FailureKind {
  offline,
  timeout,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  validation,
  rateLimited,
  tooLarge,
  server,
  unknown,
}

@immutable
class Failure implements Exception {
  const Failure(this.kind, {this.debugDetail, this.customMessage});

  final FailureKind kind;

  /// Raw technical detail. For logs and bug reports only — **never** rendered.
  final String? debugDetail;

  /// Optional human-readable override message when standard kind messages don't fit (e.g. login failed vs session expired).
  final String? customMessage;

  /// The session died; the caller should sign the user out rather than retry.
  bool get isAuth => kind == FailureKind.unauthorized;

  /// Whether offering a «retry» button makes sense. A 403 or a validation error
  /// will fail identically on a second attempt, so offering retry there is a
  /// small lie of its own.
  bool get canRetry => switch (kind) {
    FailureKind.offline ||
    FailureKind.timeout ||
    FailureKind.server ||
    FailureKind.rateLimited ||
    FailureKind.unknown => true,
    FailureKind.unauthorized ||
    FailureKind.forbidden ||
    FailureKind.notFound ||
    FailureKind.conflict ||
    FailureKind.validation ||
    FailureKind.tooLarge => false,
  };

  /// True when the cause is connectivity, so the UI can prefer showing cached
  /// data with an offline bar over an error page (§2.5).
  bool get isConnectivity =>
      kind == FailureKind.offline || kind == FailureKind.timeout;

  String message(AppLocalizations l) =>
      customMessage ??
      switch (kind) {
        FailureKind.offline => l.errNoConnection,
        FailureKind.timeout => l.errTimeout,
        FailureKind.unauthorized => l.errSessionExpired,
        FailureKind.forbidden => l.errForbidden,
        FailureKind.notFound => l.errNotFound,
        FailureKind.conflict =>
          l.isArabic
              ? 'تعارض في البيانات: قد يكون اسم المستخدم أو السجل موجوداً مسبقاً.'
              : 'Data conflict: the username or record already exists.',
        FailureKind.validation => l.errValidation,
        FailureKind.rateLimited => l.errTooManyRequests,
        FailureKind.tooLarge => l.errPayloadTooLarge,
        FailureKind.server => l.errServer,
        FailureKind.unknown => l.errUnknown,
      };

  /// Tone to render this failure in.
  ///
  /// Connectivity problems are «unknown» rather than «caution»: the app is not
  /// telling the user something went wrong with *them*, it is telling them it
  /// does not currently know. Everything else is caution.
  RiskView get tone => isConnectivity ? RiskView.unknown : RiskView.caution;

  IconData get icon => switch (kind) {
    FailureKind.offline => Icons.wifi_off_outlined,
    FailureKind.timeout => Icons.hourglass_empty_outlined,
    FailureKind.unauthorized => Icons.lock_outline,
    FailureKind.forbidden => Icons.block_outlined,
    FailureKind.notFound => Icons.search_off_outlined,
    FailureKind.conflict => Icons.warning_amber_outlined,
    FailureKind.validation => Icons.edit_note_outlined,
    FailureKind.rateLimited => Icons.timer_outlined,
    FailureKind.tooLarge => Icons.data_usage_outlined,
    FailureKind.server => Icons.cloud_off_outlined,
    FailureKind.unknown => Icons.error_outline,
  };

  /// Normalise anything thrown anywhere in the app into a [Failure].
  static Failure from(Object error) {
    if (error is Failure) return error;

    if (error is ApiException) {
      final code = error.statusCode;
      final kind = switch (code) {
        401 => FailureKind.unauthorized,
        403 => FailureKind.forbidden,
        404 => FailureKind.notFound,
        409 => FailureKind.conflict,
        413 => FailureKind.tooLarge,
        422 => FailureKind.validation,
        429 => FailureKind.rateLimited,
        // The backend rejects malformed ingest/analyze bodies with 400 and a
        // Pydantic detail; that is a client-side data problem, not an outage.
        400 => FailureKind.validation,
        _ when code != null && code >= 500 => FailureKind.server,
        _ => FailureKind.unknown,
      };
      return Failure(kind, debugDetail: '${code ?? '-'}: ${error.message}');
    }

    if (error is TimeoutException) {
      return Failure(FailureKind.timeout, debugDetail: error.message);
    }

    // Connectivity failures are matched by type *name* rather than by importing
    // `dart:io`. `SocketException` / `HandshakeException` live in `dart:io`,
    // which does not exist on web, and `main.dart` already branches on
    // `kIsWeb`. Importing it here would make this file — which every screen
    // depends on — unbuildable for web. `http` throws `ClientException` for the
    // same underlying causes.
    final typeName = error.runtimeType.toString();
    const connectivityTypes = [
      'SocketException',
      'ClientException',
      'HandshakeException',
      'HttpException',
      'TlsException',
    ];
    if (connectivityTypes.any(typeName.contains)) {
      return Failure(FailureKind.offline, debugDetail: '$typeName: $error');
    }

    // A FormatException here means the server answered with something that is
    // not the JSON we expect — a proxy interception page, for instance. From the
    // user's side that is a server problem, not their mistake.
    if (error is FormatException) {
      return Failure(FailureKind.server, debugDetail: error.message);
    }

    return Failure(FailureKind.unknown, debugDetail: '$typeName: $error');
  }

  @override
  String toString() =>
      'Failure(${kind.name}${debugDetail == null ? '' : ', $debugDetail'})';
}

/// Wrap an async call so callers deal in [Failure] only.
Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (error) {
    throw Failure.from(error);
  }
}
