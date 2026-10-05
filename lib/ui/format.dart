/// Human-friendly formatting helpers (no intl dependency needed).
library;

String formatBytes(num bytes, {int decimals = 1}) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final d = value >= 100 ? 0 : decimals;
  return '${value.toStringAsFixed(d)} ${units[unit]}';
}

String formatSpeed(double bytesPerSecond) =>
    bytesPerSecond <= 0 ? '' : '${formatBytes(bytesPerSecond)}/s';

String formatDuration(Duration d) {
  if (d.inSeconds < 1) return 'less than a second';
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) {
    final s = d.inSeconds % 60;
    return s == 0 ? '${d.inMinutes} min' : '${d.inMinutes} min ${s}s';
  }
  final m = d.inMinutes % 60;
  return '${d.inHours} h ${m.toString().padLeft(2, '0')} min';
}

String formatEta(Duration? d) => d == null ? '' : '${formatDuration(d)} left';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatDateTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today $hh:$mm';
  if (diff == 1) return 'Yesterday $hh:$mm';
  final y = t.year == n.year ? '' : ' ${t.year}';
  return '${t.day} ${_months[t.month - 1]}$y, $hh:$mm';
}

String pluralize(int n, String singular, [String? plural]) =>
    '$n ${n == 1 ? singular : (plural ?? '${singular}s')}';
