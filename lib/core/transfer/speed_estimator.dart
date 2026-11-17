import 'dart:collection';

class _SpeedSample {
  final DateTime timestamp;
  final int bytes;

  const _SpeedSample(this.timestamp, this.bytes);
}

/// Computes a smoothed transfer rate (bytes/sec) using a sliding time window
/// combined with an exponential moving average (EMA).
///
/// Feeding only positive byte deltas (never initial resume offsets) prevents
/// artificial spikes when resuming or completing concurrent tasks, and the
/// sliding window prevents dropping to 0 B/s during brief socket/buffer pauses.
class SlidingWindowSpeedEstimator {
  final Duration windowDuration;
  final double emaAlpha;
  final double minSpanSeconds;
  final DateTime Function() _clock;

  final ListQueue<_SpeedSample> _samples = ListQueue<_SpeedSample>();
  int _windowBytes = 0;
  DateTime? _firstByteTime;
  double _smoothedSpeed = 0.0;

  SlidingWindowSpeedEstimator({
    this.windowDuration = const Duration(seconds: 4),
    this.emaAlpha = 0.35,
    this.minSpanSeconds = 0.75,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  double get currentSpeed => _smoothedSpeed;

  void recordBytes(int deltaBytes) {
    if (deltaBytes <= 0) return;
    final now = _clock();
    _firstByteTime ??= now;
    _samples.addLast(_SpeedSample(now, deltaBytes));
    _windowBytes += deltaBytes;
    _prune(now);

    if (_smoothedSpeed == 0.0 && now.difference(_firstByteTime!).inMilliseconds >= 250) {
      _smoothedSpeed = _computeWindowRate(now);
    }
  }

  /// Advances one periodic sampling tick and updates the smoothed speed.
  double tick() {
    final now = _clock();
    _prune(now);

    if (_samples.isEmpty || _windowBytes <= 0) {
      _firstByteTime = null;
      _smoothedSpeed *= 0.3;
      if (_smoothedSpeed < 1024.0) {
        _smoothedSpeed = 0.0;
      }
      return _smoothedSpeed;
    }

    final windowRate = _computeWindowRate(now);
    if (_smoothedSpeed <= 0.0) {
      _smoothedSpeed = windowRate;
    } else {
      _smoothedSpeed = emaAlpha * windowRate + (1.0 - emaAlpha) * _smoothedSpeed;
    }
    return _smoothedSpeed;
  }

  void reset() {
    _samples.clear();
    _windowBytes = 0;
    _firstByteTime = null;
    _smoothedSpeed = 0.0;
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(windowDuration);
    while (_samples.isNotEmpty && _samples.first.timestamp.isBefore(cutoff)) {
      final removed = _samples.removeFirst();
      _windowBytes -= removed.bytes;
    }
    if (_windowBytes < 0) {
      _windowBytes = 0;
    }
  }

  double _computeWindowRate(DateTime now) {
    final first = _firstByteTime ?? now;
    final windowSec = windowDuration.inMilliseconds / 1000.0;
    final rawSpanSec = now.difference(first).inMilliseconds / 1000.0;
    final effectiveSpanSec = rawSpanSec.clamp(minSpanSeconds, windowSec);
    return _windowBytes / effectiveSpanSec;
  }
}
