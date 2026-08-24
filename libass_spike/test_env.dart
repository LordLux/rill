import 'dart:io';
void main() {
  try {
    Platform.environment['TEST'] = 'value';
    print('Mutable');
  } catch(e) {
    print('Immutable: $e');
  }
}
