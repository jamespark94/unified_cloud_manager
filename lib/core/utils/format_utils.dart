class FormatUtils {
  FormatUtils._();

  static String formatBytes(int bytes, {int decimals = 1}) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double dBytes = bytes.toDouble();
    while (dBytes >= 1024 && i < suffixes.length - 1) {
      dBytes /= 1024;
      i++;
    }
    return '${dBytes.toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 B/s';
    return '${formatBytes(bytesPerSecond.round())}/s';
  }

  static String formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      final hours = duration.inHours;
      final minutes = duration.inMinutes.remainder(60);
      final seconds = duration.inSeconds.remainder(60);
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (duration.inMinutes > 0) {
      final minutes = duration.inMinutes;
      final seconds = duration.inSeconds.remainder(60);
      return '${minutes}m ${seconds}s';
    } else {
      return '${duration.inSeconds}s';
    }
  }

  static String formatEta(int remainingBytes, double speedBytesPerSec) {
    if (remainingBytes <= 0) return '완료';
    if (speedBytesPerSec <= 0) return '--:--';
    final seconds = (remainingBytes / speedBytesPerSec).round();
    return formatDuration(Duration(seconds: seconds));
  }
}
