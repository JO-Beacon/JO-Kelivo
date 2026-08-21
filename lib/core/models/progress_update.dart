typedef ProgressCallback = void Function(ProgressUpdate update);

final class ProgressUpdate {
  const ProgressUpdate({this.value, this.processed, this.total});

  final double? value;
  final int? processed;
  final int? total;

  double? get fraction {
    final explicit = value;
    if (explicit != null) return explicit.clamp(0, 1).toDouble();
    final current = processed;
    final maximum = total;
    if (current == null || maximum == null || maximum <= 0) return null;
    return (current / maximum).clamp(0, 1).toDouble();
  }
}
