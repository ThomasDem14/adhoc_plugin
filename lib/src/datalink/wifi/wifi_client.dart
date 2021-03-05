import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adhoclibrary/src/datalink/exceptions/no_connection.dart';
import 'package:adhoclibrary/src/datalink/service/connection_event.dart';
import 'package:adhoclibrary/src/datalink/utils/msg_adhoc.dart';
import 'package:adhoclibrary/src/datalink/service/service.dart';
import 'package:adhoclibrary/src/datalink/service/service_client.dart';
import 'package:adhoclibrary/src/datalink/utils/utils.dart';
import 'package:flutter_wifi_p2p/flutter_wifi_p2p.dart';


class WifiClient extends ServiceClient {
  StreamController<ConnectionEvent> _connectCtrl;
  StreamController<MessageAdHoc> _messageCtrl;
  Socket _socket;
  String _serverIp;
  int _port;

  void Function(String) _connectListener;

  WifiClient(
    bool verbose, this._port, this._serverIp, int attempts, int timeOut,
  ) : super(
    verbose, Service.STATE_NONE, attempts, timeOut
  ) {
    this._connectCtrl = StreamController<ConnectionEvent>();
    this._messageCtrl = StreamController<MessageAdHoc>();
  }

/*------------------------------Getters & Setters-----------------------------*/

  set connectListener(void Function(String) connectListener) {
    this._connectListener = connectListener;
  }

  Stream<ConnectionEvent> get connStatusStream => _connectCtrl.stream;

  Stream<MessageAdHoc> get messageStream => _messageCtrl.stream;

/*-------------------------------Public methods-------------------------------*/

  Future<void> connect() async {
    await _connect(attempts, Duration(milliseconds: backOffTime));
  }

  Future<void> disconnect() async {
    await FlutterWifiP2p().removeGroup();

    _connectCtrl.add(ConnectionEvent(Service.CONNECTION_CLOSED, address: _serverIp));
  }

  void send(MessageAdHoc message) {
    if (verbose) log(ServiceClient.TAG, 'send() to $_serverIp:$_port');

    _socket.write(json.encode(message.toJson()));
  }

/*------------------------------Private methods-------------------------------*/

  Future<void> _connect(int attempts, Duration delay) async {
    try {
      await _connectionAttempt();
    } on NoConnectionException {
      if (attempts > 0) {
        if (verbose)
          log(ServiceClient.TAG, 'Connection attempt $attempts failed');

        await Future.delayed(delay);
        return _connect(attempts - 1, delay * 2);
      }

      rethrow;
    }
  }

  Future<void> _connectionAttempt() async {
    if (verbose) log(ServiceClient.TAG, 'Connect to $_serverIp : $_port');

    if (state == Service.STATE_NONE || state == Service.STATE_CONNECTING) {
      state = Service.STATE_CONNECTING;

      _socket = await Socket.connect(
        _serverIp, _port, timeout: Duration(milliseconds: timeOut)
      );

      _listen();

      _connectCtrl.add(ConnectionEvent(Service.CONNECTION_PERFORMED, address: _serverIp));

      if (_connectListener != null)
        _connectListener(_serverIp);

      if (verbose) log(ServiceClient.TAG, 'Connected to $_serverIp:$_port');

      state = Service.STATE_CONNECTED;
    }
  }

  void _listen() {
    _socket.listen(
      (data) {
        if (verbose) log(ServiceClient.TAG, 'received message from $_serverIp:${_socket.port}');

        for (MessageAdHoc msg in splitMessages(Utf8Decoder().convert(data)))
          _messageCtrl.add(msg);
      },
      onError: (error) {
        _connectCtrl.add(ConnectionEvent(Service.CONNECTION_EXCEPTION, error: error));
      },
      onDone: () {
        _connectCtrl.add(ConnectionEvent(Service.CONNECTION_CLOSED, address: _socket.remotePort.toString()));
        _socket.destroy();
        _socket.close();
      }
    );
  }
}
