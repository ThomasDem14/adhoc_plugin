import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'search_bar.dart';

import 'package:adhoc_plugin/adhoc_plugin.dart';
import 'package:analyzer_plugin/utilities/pair.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';


void main() => runApp(AdHocMusicClient());

enum MenuOptions { add, search, display, group }

const platform = const MethodChannel('adhoc.music.player/main');

class AdHocMusicClient extends StatefulWidget {
  @override
  _AdHocMusicClientState createState() => _AdHocMusicClientState();
}

class _AdHocMusicClientState extends State<AdHocMusicClient> {
  static const PLAYLIST = 0;
  static const REQUEST = 1;
  static const REPLY = 2;

  static const NONE = 'none';
  static const LOCAL = 'local';

  final TransferManager _manager = TransferManager(true);
  final List<AdHocDevice> _discovered = List.empty(growable: true);
  final List<AdHocDevice> _peers = List.empty(growable: true);
  final HashMap<String, HashMap<String, PlatformFile>> _globalPlaylist = HashMap();
  final HashMap<String, PlatformFile> _localPlaylist = HashMap();
  final List<Pair<String, String>> _playlist = List.empty(growable: true);

  // bool _peerRequest = false;
  bool _requested = false;
  bool _display = false;
  String _selected = NONE;
  String _name = LOCAL;

  @override
  void initState() {
    super.initState();
    // _manager.enableBle(3600); // TODO
    _manager.eventStream.listen(_processAdHocEvent);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: const Text('Ad Hoc Music Client'),
            actions: <Widget>[
              PopupMenuButton<MenuOptions>(
                onSelected: (MenuOptions result) async {
                  switch (result) {
                    case MenuOptions.add:
                      await _openFileExplorer();
                      break;

                    case MenuOptions.search:
                      List<String> songs = List.empty(growable: true);
                      _localPlaylist.entries.map((entry) => songs.add(entry.key));

                      _selected = await showSearch(
                        context: context,
                        delegate: SearchBar(songs),
                      );

                      if (_selected == null)
                        _selected = NONE;
                      break;

                    case MenuOptions.display:
                      setState(() => _display = !_display);
                      break;

                    case MenuOptions.group:
                      _manager.createGroup();
                      break;
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<MenuOptions>>[
                  const PopupMenuItem<MenuOptions>(
                    value: MenuOptions.add,
                    child: ListTile(
                      leading: const Icon(Icons.playlist_add),
                      title: const Text('Add song to playlist'),
                    ),
                  ),
                  const PopupMenuItem<MenuOptions>(
                    value: MenuOptions.search,
                    child: ListTile(
                      leading: const Icon(Icons.search),
                      title: const Text('Search song'),
                    ),
                  ),
                  const PopupMenuItem<MenuOptions>(
                    value: MenuOptions.display,
                    child: ListTile(
                      leading: const Icon(Icons.music_note),
                      title: const Text('Switch view'),
                    ),
                  ),
                  const PopupMenuItem<MenuOptions>(
                    value: MenuOptions.group,
                    child: ListTile(
                      leading: const Icon(Icons.create),
                      title: const Text('Create a group'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Expanded(
                child: Column(
                  children: <Widget>[
                    if (!_display) ...<Widget>[
                      Card(child: ListTile(title: Center(child: Text('Ad Hoc Peers')))),

                      ElevatedButton(
                        child: Center(child: Text('Search for nearby devices')),
                        onPressed: () => _manager.discovery(),
                      ),

                      Expanded(
                        child: ListView(
                          children: _discovered.map((device) {
                            return Card(
                              child: ListTile(
                                title: Center(child: Text(device.name)),
                                subtitle: Center(child: Text('${device.mac}')),
                                onTap: () async {
                                  await _manager.connect(device);
                                  setState(() => _discovered.removeWhere((element) => (element.mac == device.mac)));
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ] else ...<Widget>[
                      Card(child: Stack(
                        children: <Widget> [
                          ListTile(
                            title: Center(child: Text('$_selected')),
                            subtitle: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                IconButton(
                                  icon: Icon(Icons.play_arrow_rounded),
                                  onPressed: _play,
                                ),
                                IconButton(
                                  icon: Icon(Icons.pause_rounded),
                                  onPressed: _pause,
                                ),
                                IconButton(
                                  icon: Icon(Icons.stop_rounded),
                                  onPressed: _stop,
                                ),
                                if (_requested)
                                  Container(child: Center(child: CircularProgressIndicator()))
                                else
                                  Container()
                              ],
                            ),
                          ),
                        ],
                      )),

                      Card(
                        color: Colors.blue,
                        child: ListTile(
                          title: Center(
                            child: const Text('Ad Hoc Playlist', style: TextStyle(color: Colors.white)),
                          ),
                        ),
                      ),

                      Expanded(
                        child: ListView(
                          children: _playlist.map((pair) {
                            return Card(
                              child: ListTile(
                                title: Center(child: Text(pair.last)),
                                subtitle: Center(child: Text(pair.first)),
                                onTap: () => setState(() => _selected = pair.last),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _processAdHocEvent(AdHocEvent event) {
    switch (event.type) {
      case DISCOVERY_END:
        setState(() {
          (event.payload as Map).entries.forEach(
            (element) => _discovered.add(element.value)
          );
        });
        break;

      case CONNECTION_EVENT:
        _processConnection(event.payload as AdHocDevice);
        break;

      case DATA_RECEIVED:
        _processDataReceived(event.payload as List);
        break;

      case FORWARD_DATA:
        _processDataReceived(event.payload as List);
        break;

      default:
    }
  }

  void _processConnection(AdHocDevice device) {
    _peers.add(device);
  }

  void _processDataReceived(List payload) {
    AdHocDevice peer = payload.first;
    Map data = payload.last;

    switch (data['type']) {
      case PLAYLIST:
        List peers = data['peers'] as List;
        List songs = data['songs'] as List;
        String peerName = peers.first;
        HashMap<String, PlatformFile> entry = _globalPlaylist[peerName];
        if (entry == null)
          entry = HashMap();

        for (int i = 0; i < peers.length; i++) {
          if (peerName == peers[i]) {
            entry.putIfAbsent(songs[i], () => null);
          } else {
            _globalPlaylist[peerName == LOCAL ? peer.label : peerName] = entry;

            peerName = peers[i];
            entry = _globalPlaylist[peerName == LOCAL ? peer.label : peerName];
            if (entry == null)
              entry = HashMap();
            entry.putIfAbsent(songs[i], () => null);
          }

          Pair<String, String> pair = Pair(peerName, songs[i]);
          if (!_playlist.contains(pair))
            _playlist.add(pair);
        }

        _globalPlaylist[peerName == LOCAL ? peer.label : peerName] = entry;

        setState(() {});
        break;

      case REQUEST:
        // TODO: if this node has the requested song, it can send instead of the originated node
        String name = data['name'];
        Uint8List bytes;
        // PlatformFile file;

        if (_localPlaylist.containsKey(name)) {
          bytes = _localPlaylist[name].bytes;
        }

        // else {
        //   for (int i = 0; i < _globalPlaylist.length; i++) {
        //     Map entry = _globalPlaylist[i];
        //     if (entry.containsKey(name)) {
        //       file = entry[name];
        //       if (file == null) {
        //         HashMap<String, dynamic> message = HashMap();
        //         message.putIfAbsent('type', () => REQUEST);
        //         message.putIfAbsent('name', () => name);
        //         // Send label of requester too so that originated node send directly
        //         _manager.sendMessageTo(message, _globalPlaylist.keys.elementAt(i));
        //         _peerRequest = true;
        //       }

        //       break;
        //     }
        //   }
        // }

        HashMap<String, dynamic> message = HashMap();
        message.putIfAbsent('type', () => REPLY);
        message.putIfAbsent('name', () => name);
        message.putIfAbsent('song', () => bytes);
        _manager.sendMessageTo(message, peer.label);
        // _manager.sendEncryptedMessageTo(message, peer.label);
        break;

      case REPLY:
        _processReply(peer, data);
        break;

      default:
    }
  }

  void _processReply(AdHocDevice peer, Map data) async {
    // TODO: Requester node should wait for multiple possible request so check with name of file
    String name = data['name'];
    Uint8List song = Uint8List.fromList((data['song'] as List<dynamic>).cast<int>());

    Directory tempDir = await getTemporaryDirectory();
    File tempFile = File('${tempDir.path}/$name');
    await tempFile.writeAsBytes(song, flush: true);

    HashMap<String, PlatformFile> entry = HashMap();
    entry.putIfAbsent(
      name, () => PlatformFile(bytes: song, name: name, path: tempFile.path)
    );

    _globalPlaylist.update(peer.label, (value) => entry, ifAbsent: () => entry);
    setState(() => _requested = false);
  }

  Future<void> _openFileExplorer() async {
    FilePickerResult result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.audio,
    );

    if(result != null) {
      for (PlatformFile file in result.files) {
        PlatformFile song = PlatformFile(
          name: file.name,
          path: file.path,
          bytes: await File(file.path).readAsBytes(),
        );

        _localPlaylist.putIfAbsent(file.name, () => song);
        Pair<String, String> pair = Pair(_name, file.name);
        if (!_playlist.contains(pair))
          _playlist.add(pair);
      }
    }

    _updatePlaylist();
  }

  void _updatePlaylist() async {
    List<String> peers = List.empty(growable: true);
    List<String> songs = List.empty(growable: true);

    _globalPlaylist.forEach((peer, song) {
      peers.add(peer);
      song.forEach((key, value) {
        songs.add(key);
      });
    });

    _localPlaylist.forEach((name, file) {
      peers.add(_name);
      songs.add(name);
    });

    HashMap<String, dynamic> message = HashMap();
    message.putIfAbsent('type', () => PLAYLIST);
    message.putIfAbsent('peers', () => peers);
    message.putIfAbsent('songs', () => songs);
    _manager.broadcast(message);
  }

  void _play() {
    if (_selected.compareTo(NONE) == 0)
      return;

    PlatformFile file;
    if (_localPlaylist.containsKey(_selected)) {
      file = _localPlaylist[_selected];
    } else {
      _globalPlaylist.forEach((peerName, playlist) {
        if (playlist.containsKey(_selected)) {
          file = playlist[_selected];
          if (file == null) {
            HashMap<String, dynamic> message = HashMap();
            message.putIfAbsent('type', () => REQUEST);
            message.putIfAbsent('name', () => _selected);
            _manager.broadcast(message);

            setState(() => _requested = true);
          }
        }
      });
    }

    if (_requested == false)
      platform.invokeMethod('play', file.path);
  }

  void _pause() {
    if (_selected.compareTo(NONE) == 0)
      return;

    platform.invokeMethod('pause');
  }

  void _stop() {
    if (_selected.compareTo(NONE) == 0)
      return;

    _selected = NONE;
    platform.invokeMethod('stop');

    setState(() {});
  }
}
