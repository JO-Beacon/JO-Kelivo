/// 按 IEC 80000-13 标注字节单位：二进制前缀（1024 进制）带 i，
/// 即 KiB／MiB／GiB；十进制前缀（1000 进制）不带 i，即 KB／MB／GB。
/// 本仓库一律以 1024 为基准，因此标签固定带 i。
String formatBytes(int bytes) {
  const kib = 1024;
  const mib = 1024 * kib;
  const gib = 1024 * mib;
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(2)} GiB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(2)} MiB';
  if (bytes >= kib) return '${(bytes / kib).toStringAsFixed(1)} KiB';
  return '$bytes B';
}
