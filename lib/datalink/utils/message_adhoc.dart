import 'package:AdHocLibrary/datalink/utils/header.dart';

class MessageAdHoc {
  Header _header;

  MessageAdHoc([this._header]);

  set header(Header header) => this._header = header;

  Header get header => _header;
}