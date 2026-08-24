import 'package:flutter_riverpod/flutter_riverpod.dart';

class LibassFlag extends Notifier<bool> {
  @override
  bool build() => false;
  
  void toggle() => state = !state;
  void set(bool val) => state = val;
}

final libassEnabledProvider = NotifierProvider<LibassFlag, bool>(LibassFlag.new);
