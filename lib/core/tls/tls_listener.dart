import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anyware/core/logger.dart';

/// One port for plain HTTP and TLS, told apart by the first byte as LifeOS
/// does (lifeos_store/yakin.py `_Server.finish_request`): a TLS hello starts
/// with 0x16, HTTP with a letter. Old peers (protocol 1.1) keep speaking
/// plain HTTP to the same port, and no new firewall port is needed.
///
/// Hand [sockets] to `HttpServer.listenOn`; [isSecure] tells a request's
/// connection apart afterwards.
class TlsListener {
  TlsListener._(this._server, this._context);

  static final _log = AppLogger('TlsListener');

  final ServerSocket _server;
  final SecurityContext? _context;
  final StreamController<Socket> _accepted = StreamController<Socket>();

  /// Remote "ip:port" of the connections that came in over TLS.
  final Set<String> _secure = {};

  /// Binds [port]. Without a [context] every connection is plain HTTP.
  static Future<TlsListener> bind(
    InternetAddress address,
    int port, {
    SecurityContext? context,
    bool shared = false,
  }) async {
    final server = await ServerSocket.bind(address, port, shared: shared);
    final listener = TlsListener._(server, context);
    server.listen(
      listener._accept,
      onError: listener._accepted.addError,
      onDone: listener._accepted.close,
    );
    return listener;
  }

  /// The accepted connections, ready for `HttpServer.listenOn`.
  ServerSocket get sockets => _Sockets(_server, _accepted.stream);

  int get port => _server.port;

  /// Whether the connection from [remote] came in over TLS.
  bool isSecure(InternetAddress remote, int remotePort) =>
      _secure.contains('${remote.address}:$remotePort');

  Future<void> close() async {
    await _server.close();
  }

  void _accept(Socket socket) {
    late final StreamSubscription<Uint8List> first;
    final timeout = Timer(const Duration(seconds: 15), socket.destroy);
    first = socket.listen(
      (data) async {
        // the first piece decides; the subscription is paused (never
        // cancelled: TLS takes the socket over from here)
        first.pause();
        timeout.cancel();
        final context = _context;
        if (data.isNotEmpty && data[0] == 0x16 && context != null) {
          try {
            final secure = await SecureSocket.secureServer(
              socket,
              context,
              bufferedData: data,
            );
            final key = '${secure.remoteAddress.address}:${secure.remotePort}';
            _secure.add(key);
            secure.done.whenComplete(() => _secure.remove(key)).ignore();
            _accepted.add(secure);
          } catch (e) {
            // a sender that met a certificate it did not expect hangs up
            _log.debug('TLS handshake failed: $e');
          }
        } else {
          _accepted.add(_Replayed(socket, data, first));
        }
      },
      onError: (_) => socket.destroy(),
      onDone: timeout.cancel,
      cancelOnError: true,
    );
  }
}

class _Sockets extends Stream<Socket> implements ServerSocket {
  _Sockets(this._server, this._stream);

  final ServerSocket _server;
  final Stream<Socket> _stream;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  InternetAddress get address => _server.address;

  @override
  int get port => _server.port;

  @override
  Future<ServerSocket> close() async {
    await _server.close();
    return this;
  }
}

/// A plain connection whose first piece, already read to tell HTTP from
/// TLS, is given back to the reader first.
class _Replayed extends Stream<Uint8List> implements Socket {
  _Replayed(this._inner, this._head, this._subscription);

  final Socket _inner;
  final Uint8List _head;
  final StreamSubscription<Uint8List> _subscription;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>(
      onPause: _subscription.pause,
      onResume: _subscription.resume,
      onCancel: _subscription.cancel,
    );
    controller.add(_head);
    _subscription
      ..onData(controller.add)
      ..onError(controller.addError)
      ..onDone(controller.close)
      ..resume();
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() => _inner.destroy();

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;

  @override
  int get remotePort => _inner.remotePort;
}
