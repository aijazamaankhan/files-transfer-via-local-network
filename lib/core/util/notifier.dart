import 'dart:async';

/// Minimal listener-based observable for core classes (which must not depend
/// on Flutter). The UI adapts it with `NotifierBuilder`.
class Notifier {
  final List<void Function()> _listeners = [];
  bool _disposed = false;

  void addListener(void Function() listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    if (_disposed) return;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void disposeNotifier() {
    _disposed = true;
    _listeners.clear();
  }
}

/// A notifier that coalesces high-frequency changes (e.g. progress updates)
/// into at most one notification per [interval].
class ThrottledNotifier extends Notifier {
  ThrottledNotifier({this.interval = const Duration(milliseconds: 150)});

  final Duration interval;
  Timer? _timer;
  bool _pending = false;

  /// Schedules a notification, rate-limited.
  void markDirty() {
    if (_timer != null) {
      _pending = true;
      return;
    }
    notifyListeners();
    _timer = Timer(interval, () {
      _timer = null;
      if (_pending) {
        _pending = false;
        markDirty();
      }
    });
  }

  /// Notifies immediately (state transitions should never be delayed).
  void notifyNow() {
    _pending = false;
    notifyListeners();
  }

  @override
  void disposeNotifier() {
    _timer?.cancel();
    super.disposeNotifier();
  }
}
