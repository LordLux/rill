import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// The updater's only network surface, so tests can replace it whole.
abstract interface class UpdateHttp {
  /// GET the whole body. Throws [UpdateNetworkException] on a non-200, a
  /// timeout, a socket error, or a body longer than [maxBytes].
  Future<Uint8List> getBytes(Uri url, {required int maxBytes});

  /// GET as a stream of chunks; a stall longer than the idle timeout ends the
  /// stream with [UpdateNetworkException].
  Future<Stream<List<int>>> openStream(Uri url);
}

class UpdateNetworkException implements Exception {
  UpdateNetworkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `dart:io` with one shared client, the same arrangement as
/// `storyboard_sheets.dart`. Redirects are followed (the feed is a GitHub
/// `latest/download` redirect), and a chain that lands anywhere but https is
/// refused unless the request was to the loopback test feed.
class IoUpdateHttp implements UpdateHttp {
  static const _responseTimeout = Duration(seconds: 30);
  static const _idleTimeout = Duration(seconds: 60);

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'rill-updater';

  @override
  Future<Uint8List> getBytes(Uri url, {required int maxBytes}) => _guard(() async {
    final response = await _open(url);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_responseTimeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw UpdateNetworkException('$url is larger than $maxBytes bytes');
      }
    }
    return builder.takeBytes();
  });

  @override
  Future<Stream<List<int>>> openStream(Uri url) => _guard(() async {
    final response = await _open(url);
    return response.timeout(
      _idleTimeout,
      onTimeout: (sink) => sink
        ..addError(UpdateNetworkException('download stalled for ${_idleTimeout.inSeconds} s'))
        ..close(),
    );
  });

  Future<HttpClientResponse> _open(Uri url) async {
    final request = await _client.getUrl(url);
    final response = await request.close().timeout(_responseTimeout);
    final loopback = url.scheme == 'http' && url.host == '127.0.0.1';
    var at = url;
    for (final hop in response.redirects) {
      at = at.resolveUri(hop.location);
      if (at.scheme != 'https' && !loopback) {
        await response.drain<void>().catchError((_) {});
        throw UpdateNetworkException('refusing a redirect to ${at.scheme}');
      }
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      throw UpdateNetworkException('HTTP ${response.statusCode} from $url');
    }
    return response;
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on UpdateNetworkException {
      rethrow;
    } on Object catch (error) {
      // SocketException, HttpException, TimeoutException, TLS failures: all a
      // network problem from where the updater stands.
      throw UpdateNetworkException('$error');
    }
  }
}
