import 'dart:collection';

/// Measures throughput over a sliding window and estimates time remaining.
class SpeedMeter {
  SpeedMeter({
    this.window = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration window;
  final DateTime Function() _clock;
  final Queue<(DateTime, int)> _samples = Queue();
  int _total = 0;

  /// Records [bytes] newly transferred.
  void add(int bytes) {
    _total += bytes;
    final now = _clock();
    _samples.add((now, _total));
    _trim(now);
  }

  void _trim(DateTime now) {
    while (_samples.length > 2 && now.difference(_samples.first.$1) > window) {
      _samples.removeFirst();
    }
  }

  /// Resets the window (e.g. after a pause) without losing the total.
  void resetWindow() => _samples.clear();

  /// Bytes per second over the current window. 0 when unknown.
  double get bytesPerSecond {
    if (_samples.length < 2) return 0;
    final now = _clock();
    _trim(now);
    final first = _samples.first;
    final last = _samples.last;
    // Measure up to "now" so speed decays when data stops flowing.
    final ms = now.difference(first.$1).inMilliseconds;
    if (ms <= 0) return 0;
    return (last.$2 - first.$2) * 1000 / ms;
  }

  /// Estimated remaining time for [remainingBytes], or null if unknown.
  Duration? eta(int remainingBytes) {
    final bps = bytesPerSecond;
    if (bps <= 1) return null;
    return Duration(milliseconds: (remainingBytes / bps * 1000).round());
  }
}
