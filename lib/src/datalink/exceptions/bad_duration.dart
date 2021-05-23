import 'dart:core';


/// Class signaling that a Bad Duration exception has been triggered due to 
/// invalid duration given.
class BadDurationException implements Exception {
  String _message;

  /// Creates a [BadDurationException] object.
  /// 
  /// Displays the exception [_message] if it is given, otherwise "Bad duration"
  /// is displayed.
  BadDurationException([this._message = 'Bad duration']);

  @override
  String toString() => _message;
}
