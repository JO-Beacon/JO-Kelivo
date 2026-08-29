import 'dart:ffi';

import 'package:flutter/foundation.dart';

@Native<Void Function(Pointer<Void>)>(
  assetId: 'package:sqlite3/src/ffi/libsqlite3.g.dart',
  symbol: 'sqlite3_interrupt',
)
external void _sqlite3Interrupt(Pointer<Void> db);

@visibleForTesting
void Function(int handleAddress)? debugOnInterruptSqliteHandle;

void interruptSqliteHandle(int handleAddress) {
  if (handleAddress == 0) return;
  final hook = debugOnInterruptSqliteHandle;
  if (hook != null) {
    hook(handleAddress);
    return;
  }
  try {
    _sqlite3Interrupt(Pointer<Void>.fromAddress(handleAddress));
  } catch (_) {
    // 某些平台的 sqlite 原生库可能未导出该符号；runner 仍会终止 worker。
  }
}
