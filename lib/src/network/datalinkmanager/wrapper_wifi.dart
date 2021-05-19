import 'dart:async';
import 'dart:collection';

import 'package:adhoc_plugin/src/appframework/config.dart';
import 'package:adhoc_plugin/src/datalink/service/adhoc_device.dart';
import 'package:adhoc_plugin/src/datalink/service/adhoc_event.dart';
import 'package:adhoc_plugin/src/datalink/service/constants.dart';
import 'package:adhoc_plugin/src/datalink/service/service.dart';
import 'package:adhoc_plugin/src/datalink/service/service_client.dart';
import 'package:adhoc_plugin/src/datalink/utils/msg_adhoc.dart';
import 'package:adhoc_plugin/src/datalink/utils/msg_header.dart';
import 'package:adhoc_plugin/src/datalink/utils/utils.dart';
import 'package:adhoc_plugin/src/datalink/wifi/wifi_adhoc_device.dart';
import 'package:adhoc_plugin/src/datalink/wifi/wifi_adhoc_manager.dart';
import 'package:adhoc_plugin/src/datalink/wifi/wifi_client.dart';
import 'package:adhoc_plugin/src/datalink/wifi/wifi_server.dart';
import 'package:adhoc_plugin/src/network/datalinkmanager/constants.dart';
import 'package:adhoc_plugin/src/network/datalinkmanager/flood_msg.dart';
import 'package:adhoc_plugin/src/network/datalinkmanager/network_manager.dart';
import 'package:adhoc_plugin/src/network/datalinkmanager/wrapper_network.dart';


/// Class inheriting the abstract class [WrapperNetwork] and manages all 
/// communications related to Wi-Fi Direct
class WrapperWifi extends WrapperNetwork {
  static const String TAG = "[WrapperWifi]";

  String? _ownIPAddress;
  String? _groupOwnerAddr;
  WifiAdHocManager? _wifiManager;

  late bool _isListening;
  late bool _isConnecting;
  late bool _isGroupOwner;
  late bool _isDiscovering;
  late int _serverPort;
  late HashMap<String?, String?> _mapIPAddressMac;
  late StreamSubscription<AdHocEvent> _eventSub;

  WrapperWifi(
    bool verbose, Config config, HashMap<String?, AdHocDevice?> mapMacDevices
  ) : super(verbose, config, mapMacDevices) {
    this.type = WIFI;
    this._isListening = false;
    this._isConnecting = false;
    this._isGroupOwner = false;
    this._isDiscovering = false;
    this._mapIPAddressMac = HashMap();
    this.init(verbose, config);
  }

/*------------------------------Getters & Setters-----------------------------*/

  bool get isGroupOwner => _isGroupOwner;

/*------------------------------Override methods------------------------------*/

  @override
  void init(bool verbose, Config config) async {
    _serverPort = config.serverPort;

    if (await (WifiAdHocManager.isWifiEnabled() as Future<bool>)) {
      this._wifiManager = WifiAdHocManager(verbose, _onWifiReady)..register(_registration);
      this._isGroupOwner = false;
      this.ownName = await _wifiManager!.adapterName;
      this._initialize();
      this.enabled = true;
    } else {
      this.enabled = false;
    }
  }

  @override
  void enable(int duration) {
    _wifiManager = WifiAdHocManager(verbose, _onWifiReady)..register(_registration);

    enabled = true;
  }

  @override 
  void disable() {
    mapAddrNetwork.clear();
    neighbors.clear();

    _wifiManager = null;

    enabled = false;
  }

  @override
  void discovery() {
    if (_isDiscovering)
      return;

    _eventSub.resume();
    _wifiManager!.discovery();
    _isDiscovering = true;
  }

  @override
  Future<void> connect(int attempts, AdHocDevice device) async {
    WifiAdHocDevice? wifiAdHocDevice = mapMacDevices[device.mac] as WifiAdHocDevice?;
    if (wifiAdHocDevice != null) {
      this.attempts = attempts;
      await _wifiManager!.connect(device.mac);
    }
  }

  @override
  void stopListening() {
    serviceServer.stopListening();
    _isListening = false;
  }

  @override // Not used in wifi context
  Future<HashMap<String, AdHocDevice>>? getPaired() => null;

  @override
  Future<String?> getAdapterName() async {
    return await _wifiManager!.adapterName;
  }

  @override
  Future<bool?> updateDeviceName(final String name) async {
    return await _wifiManager!.updateDeviceName(name);
  }

  @override
  Future<bool?> resetDeviceName() async {
    return await _wifiManager!.resetDeviceName();
  }

/*-------------------------------Public methods-------------------------------*/

  void unregister() => _wifiManager!.unregister();

  void removeGroup() {
    _mapIPAddressMac.forEach((address, mac) async {
      await serviceServer.cancelConnection(mac);
    });

    serviceServer.activeConnections!.clear();

    _wifiManager!.removeGroup();
  }

  bool? isWifiGroupOwner() => _isGroupOwner;

/*------------------------------Private methods-------------------------------*/

  void _initialize() {
    _eventSub = _wifiManager!.eventStream.listen((AdHocEvent event) {
      controller.add(event);

      switch (event.type) {
        case DEVICE_DISCOVERED:
          WifiAdHocDevice device = event.payload as WifiAdHocDevice;
          mapMacDevices.putIfAbsent(device.mac, () {
            if (verbose) log(TAG, "Add " + device.mac! + " into mapMacDevices");
            return device;
          });
          break;

        case DISCOVERY_END:
          if (verbose) log(TAG, 'Discovery end');
          (event.payload as Map<String, WifiAdHocDevice>).forEach((mac, device) {
            mapMacDevices.putIfAbsent(mac, () {
              if (verbose) log(TAG, "Add " + mac + " into mapMacDevices");
              return device;
            });
          });

          discoveryCompleted = true;
          _isDiscovering = false;
          _eventSub.pause();
          break;

        default:
          break;
      }
    });

    _eventSub.pause();
  }

  void _registration(
    bool isConnected, bool isGroupOwner, String groupOwnerAddress
  ) {
    _isGroupOwner = isGroupOwner;
    if (isConnected && _isGroupOwner) {
      _groupOwnerAddr = _ownIPAddress = groupOwnerAddress;
      if (!_isListening) {
        _listenServer();
        _isListening = true;
      }
    } else if (isConnected && !_isGroupOwner) {
      _groupOwnerAddr = groupOwnerAddress;
      if (!_isConnecting) {
        _connect(_serverPort);
        _isConnecting = true;
      }
    }
  }

  void _onWifiReady(String ipAddress, String mac) {
    _ownIPAddress = ipAddress;
    ownMac = mac;
  }

  void _onEvent(Service service) {
    service.adhocEvent.listen((event) async { 
      switch (event.type) {
        case MESSAGE_RECEIVED:
          _processMsgReceived(event.payload as MessageAdHoc);
          break;

        case CONNECTION_PERFORMED:
          if (_ownIPAddress == _groupOwnerAddr)
            break;

          String? remoteAddress = event.payload as String?;
          mapAddrNetwork.putIfAbsent(
            remoteAddress,
            () => NetworkManager(
              (MessageAdHoc? msg) async => (service as ServiceClient).send(msg!), 
              () => (service as ServiceClient).disconnect()
            )
          );

          ownName = await _wifiManager!.adapterName;
          controller.add(AdHocEvent(DEVICE_INFO_WIFI, [ownMac, ownName]));

          (service as ServiceClient).send(
            MessageAdHoc(
              Header(
                messageType: CONNECT_SERVER,
                label: ownLabel,
                name: ownName,
                mac: ownMac,
                address: _ownIPAddress,
                deviceType: WIFI
              ),
            )
          );
          break;

        case CONNECTION_ABORTED:
          connectionClosed(_mapIPAddressMac[event.payload as String]);
          break;

        case CONNECTION_EXCEPTION:
          controller.add(AdHocEvent(INTERNAL_EXCEPTION, event.payload));
          break;

        default:
      }
    });
  }

  void _listenServer() {
    serviceServer = WifiServer(verbose)..listen(_ownIPAddress, _serverPort);
    _onEvent(serviceServer);
  }

  void _connect(int? remotePort) async {
    final wifiClient = WifiClient(verbose, remotePort, _groupOwnerAddr, attempts, timeOut);
    _onEvent(wifiClient);
    await wifiClient.connect();
  }

  void _processMsgReceived(MessageAdHoc message) async {
    switch (message.header!.messageType) {
      case CONNECT_SERVER:
        String? remoteAddress = message.header!.address;
        _mapIPAddressMac.putIfAbsent(
          remoteAddress, () => message.header!.mac
        );

        ownName = await _wifiManager!.adapterName;
        controller.add(AdHocEvent(DEVICE_INFO_WIFI, [ownMac, ownName]));

        serviceServer.send(
          MessageAdHoc(Header(
            messageType: CONNECT_CLIENT,
            label: ownLabel,
            name: ownName,
            mac: ownMac,
            address: _ownIPAddress,
            deviceType: type
          )),
          remoteAddress
        );

        receivedPeerMessage(
          message.header!,
          NetworkManager(
            (MessageAdHoc? msg) => serviceServer.send(msg!, remoteAddress),
            () => serviceServer.cancelConnection(remoteAddress)
          )
        );
        break;

      case CONNECT_CLIENT:
        _mapIPAddressMac.putIfAbsent(
          message.header!.address, () => message.header!.mac
        );

        NetworkManager? network = mapAddrNetwork[message.header!.address];
        receivedPeerMessage(message.header!, network);
        break;

      case CONNECT_BROADCAST:
        FloodMsg floodMsg = FloodMsg.fromJson((message.pdu as Map) as Map<String, dynamic>);
        if (checkFloodEvent(floodMsg.id)) {
          broadcastExcept(message, message.header!.label);

          HashSet<AdHocDevice?> hashSet = floodMsg.devices;
          for (AdHocDevice? device in hashSet) {
            if (device!.label != ownLabel && !setRemoteDevices.contains(device)
              && !isDirectNeighbors(device.label)
            ) {
              controller.add(AdHocEvent(CONNECTION_EVENT, device));

              setRemoteDevices.add(device);
            }
          }
        }
        break;

      case DISCONNECT_BROADCAST:
        if (checkFloodEvent(message.pdu as String?)) {
          broadcastExcept(message, message.header!.label);

          Header header = message.header!;
          AdHocDevice device = AdHocDevice(
            label: header.label,
            name: header.name,
            mac: header.mac,
            type: type!
          );

          controller.add(AdHocEvent(DISCONNECTION_EVENT, device));

          if (setRemoteDevices.contains(device))
            setRemoteDevices.remove(device);
        }
        break;

      case BROADCAST:
        Header header = message.header!;
        AdHocDevice device = AdHocDevice(
          label: header.label,
          name: header.name,
          mac: header.mac,
          type: header.deviceType!
        );

        controller.add(AdHocEvent(DATA_RECEIVED, [device, message.pdu]));
        break;

      default:
        controller.add(AdHocEvent(MESSAGE_EVENT, message));
        break;
    }
  }
}
