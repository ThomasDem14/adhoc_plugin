import 'dart:collection';

import 'package:adhoclibrary/src/appframework/config.dart';
import 'package:adhoclibrary/src/appframework/listener_adapter.dart';
import 'package:adhoclibrary/src/appframework/listener_app.dart';
import 'package:adhoclibrary/src/datalink/ble/ble_adhoc_device.dart';
import 'package:adhoclibrary/src/datalink/ble/ble_adhoc_manager.dart';
import 'package:adhoclibrary/src/datalink/ble/ble_client.dart';
import 'package:adhoclibrary/src/datalink/ble/ble_server.dart';
import 'package:adhoclibrary/src/datalink/ble/ble_utils.dart';
import 'package:adhoclibrary/src/datalink/exceptions/device_failure.dart';
import 'package:adhoclibrary/src/datalink/service/adhoc_device.dart';
import 'package:adhoclibrary/src/datalink/service/discovery_event.dart';
import 'package:adhoclibrary/src/datalink/service/service.dart';
import 'package:adhoclibrary/src/datalink/utils/msg_adhoc.dart';
import 'package:adhoclibrary/src/datalink/utils/msg_header.dart';
import 'package:adhoclibrary/src/network/datalinkmanager/abstract_wrapper.dart';
import 'package:adhoclibrary/src/network/datalinkmanager/flood_msg.dart';
import 'package:adhoclibrary/src/network/datalinkmanager/network_manager.dart';
import 'package:adhoclibrary/src/network/datalinkmanager/wrapper_conn_oriented.dart';


class WrapperBluetoothLE extends WrapperConnOriented {
  static const String TAG = "[WrapperBle]";

  BleAdHocManager _bleAdHocManager;
  String _ownStringUUID;

  WrapperBluetoothLE(
    bool verbose, Config config, HashMap<String, AdHocDevice> mapMacDevices,
    ListenerApp listenerApp
  ) : super(verbose, config, mapMacDevices, listenerApp) {
    this.type = Service.BLUETOOTHLE;
    this.init(verbose);
  }

/*------------------------------Override methods------------------------------*/

  @override
  Future<void> init(bool verbose, [Config config]) async {
    if (await BleAdHocManager.isEnabled()) {
      _bleAdHocManager = BleAdHocManager(verbose);
      ownName = await BleAdHocManager.getCurrentName();
      _listenServer();

      enabled = true;
    }
  }

  @override
  void enable(int duration, ListenerAdapter listenerAdapter) async {
    if (!enabled) {
      _bleAdHocManager = BleAdHocManager(v);
      _bleAdHocManager.enable();
      _bleAdHocManager.onEnableBluetooth(listenerAdapter);

      ownName = await BleAdHocManager.getCurrentName();
      _listenServer();

      enabled = true;
    }

    _bleAdHocManager.enableDiscovery(duration);
  }

  @override
  void disable() {
    neighbors.neighbors.clear();

    _bleAdHocManager.disable();
    _bleAdHocManager = null;

    enabled = false;
  }

  @override
  void discovery(
    void onEvent(DiscoveryEvent event), void onError(dynamic error),
  ) {
    _bleAdHocManager.discovery((DiscoveryEvent event) {
      onEvent(event);

      if (event.type == Service.DEVICE_DISCOVERED) {
        BleAdHocDevice device = event.payload as BleAdHocDevice;
        mapMacDevices.putIfAbsent(device.mac, () => device);
      } else if (event.type == Service.DISCOVERY_END) {
        HashMap<String, AdHocDevice> discoveredDevices = 
          event.payload as HashMap<String, AdHocDevice>;

          discoveredDevices.forEach((mac, device) {
            mapMacDevices.putIfAbsent(mac, () => device);
          });

          discoveryCompleted = true;
      }
    }, onError);
  }

  @override
  void connect(int attempts, AdHocDevice adHocDevice) {
    BleAdHocDevice bleAdHocDevice = mapMacDevices[adHocDevice.mac];
    if (bleAdHocDevice != null) {
      if (!serviceServer.containConnection(bleAdHocDevice.mac)) {
        _connect(attempts, bleAdHocDevice);
      } else {
        throw DeviceFailureException(
          adHocDevice.name + "(" + adHocDevice.mac + ") is already connected"
        );
      }
    }
  }

  @override
  void stopListening() => serviceServer.stopListening();

  @override
  Future<HashMap<String, AdHocDevice>> getPaired() async {
    if (!(await BleAdHocManager.isEnabled()))
      return null;

    Map pairedDevices = await _bleAdHocManager.getPairedDevices();
    pairedDevices.forEach((macAddress, bleAdHocDevice) {
      mapMacDevices.putIfAbsent(macAddress, () => bleAdHocDevice);
    });

    return mapMacDevices;
  }

  @override
  Future<String> getAdapterName() async {
    return await _bleAdHocManager.adapterName;
  }

  @override
  Future<bool> updateDeviceName(String name) async {
    return await _bleAdHocManager.updateDeviceName(name);
  }

  @override
  Future<bool> resetDeviceName() async {
    return await _bleAdHocManager.resetDeviceName();
  }

/*------------------------------Private methods-------------------------------*/

  void _onEvent(DiscoveryEvent event) {
    switch (event.type) {
      case Service.MESSAGE_RECEIVED:
        _processMsgReceived(event.payload as MessageAdHoc);
        break;

      case Service.CONNECTION_PERFORMED:
        break;

      case Service.CONNECTION_CLOSED:
        connectionClosed(event.payload as String);
        break;
    }
  }

  void _onError(dynamic error) => print(error.toString());

  void _listenServer() {
    serviceServer = BleServer(v, _onEvent, _onError)..listen();
  }

  void _connect(int attempts, final BleAdHocDevice bleAdHocDevice) {
    final bleClient = BleClient(
      v, bleAdHocDevice, attempts, timeOut, _onEvent, _onError
    );

    bleClient.connectListener = (String remoteAddress, String uuid) async {
      await bleClient.send(MessageAdHoc(
        Header(
          messageType: AbstractWrapper.CONNECT_SERVER, 
          label: label,
          name: ownName,
          mac: ownMac,
          address: _ownStringUUID
        ),
        remoteAddress
      ));

      mapAddrNetwork.putIfAbsent(
        uuid,
        () => NetworkManager(
          remoteAddress, bleClient.send, bleClient.disconnect
        )
      );
    };

    bleClient..connect()..listen();
  }

  void _processMsgReceived(final MessageAdHoc message) {
    switch (message.header.messageType) {
      case AbstractWrapper.CONNECT_SERVER:
        String mac = message.header.mac;
        ownMac = message.pdu as String;
        _ownStringUUID = BleUtils.BLUETOOTHLE_UUID +
          ownMac.replaceAll(new RegExp(':'), '').toLowerCase();

        serviceServer.send(
          MessageAdHoc(
            Header(
              messageType: AbstractWrapper.CONNECT_CLIENT, 
              label: label, 
              name: ownName,
              address: _ownStringUUID,
              mac: ownMac,
            ),
            mac
          ),
          mac
        );

        receivedPeerMessage(
          message.header, 
          NetworkManager(
            mac,
            (MessageAdHoc msg) => serviceServer.send(msg, mac),
            () => serviceServer.cancelConnection(mac)
          )
        );
        break;

      case AbstractWrapper.CONNECT_CLIENT:
        ownMac = message.pdu as String;
        _ownStringUUID = BleUtils.BLUETOOTHLE_UUID +
          ownMac.replaceAll(new RegExp(':'), '').toLowerCase();

        NetworkManager network = mapAddrNetwork[message.header.address];
        receivedPeerMessage(message.header, network);
        break;

      case AbstractWrapper.CONNECT_BROADCAST:
        if (checkFloodEvent((message.pdu as FloodMsg).id)) {
          broadcastExcept(message, message.header.label);

          HashSet<AdHocDevice> hashSet = (message.pdu as FloodMsg).adHocDevices;
          for (AdHocDevice adHocDevice in hashSet) {
            if (adHocDevice.label == label 
              && !setRemoteDevices.contains(adHocDevice)
              && !isDirectNeighbors(adHocDevice.label)
            ) {
              adHocDevice.directedConnected = false;

              listenerApp.onConnection(adHocDevice);

              setRemoteDevices.add(adHocDevice);
            }
          }
        }
        break;

      case AbstractWrapper.DISCONNECT_BROADCAST:
        if (checkFloodEvent(message.pdu as String)) {
          broadcastExcept(message, message.header.label);

          Header header = message.header;
          AdHocDevice adHocDevice = AdHocDevice(
            label: header.label,
            name: header.name,
            mac: header.mac,
            type: type, 
            directedConnected: false
          );

          listenerApp.onConnectionClosed(adHocDevice);

          if (setRemoteDevices.contains(adHocDevice))
              setRemoteDevices.remove(adHocDevice);
        }
        break;

      case AbstractWrapper.BROADCAST:
        Header header = message.header;

        listenerApp.onReceivedData(
          AdHocDevice(
            name: header.name,
            label: header.label,
            type: type
          ),
          message.pdu
        );
        break;
      
      default:
    }
  }
}
