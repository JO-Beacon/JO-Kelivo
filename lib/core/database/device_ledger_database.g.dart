// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_ledger_database.dart';

// ignore_for_file: type=lint
class $DeviceLocalSettingsLedgerRowsTable extends DeviceLocalSettingsLedgerRows
    with
        TableInfo<
          $DeviceLocalSettingsLedgerRowsTable,
          DeviceLocalSettingsLedgerRow
        > {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeviceLocalSettingsLedgerRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceNameMeta = const VerificationMeta(
    'deviceName',
  );
  @override
  late final GeneratedColumn<String> deviceName = GeneratedColumn<String>(
    'device_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _platformMeta = const VerificationMeta(
    'platform',
  );
  @override
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
    'platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _savedAtUtcMeta = const VerificationMeta(
    'savedAtUtc',
  );
  @override
  late final GeneratedColumn<DateTime> savedAtUtc = GeneratedColumn<DateTime>(
    'saved_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valuesJsonMeta = const VerificationMeta(
    'valuesJson',
  );
  @override
  late final GeneratedColumn<String> valuesJson = GeneratedColumn<String>(
    'values_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    fingerprint,
    deviceName,
    platform,
    savedAtUtc,
    valuesJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'device_local_settings_ledger_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeviceLocalSettingsLedgerRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('device_name')) {
      context.handle(
        _deviceNameMeta,
        deviceName.isAcceptableOrUnknown(data['device_name']!, _deviceNameMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceNameMeta);
    }
    if (data.containsKey('platform')) {
      context.handle(
        _platformMeta,
        platform.isAcceptableOrUnknown(data['platform']!, _platformMeta),
      );
    } else if (isInserting) {
      context.missing(_platformMeta);
    }
    if (data.containsKey('saved_at_utc')) {
      context.handle(
        _savedAtUtcMeta,
        savedAtUtc.isAcceptableOrUnknown(
          data['saved_at_utc']!,
          _savedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_savedAtUtcMeta);
    }
    if (data.containsKey('values_json')) {
      context.handle(
        _valuesJsonMeta,
        valuesJson.isAcceptableOrUnknown(data['values_json']!, _valuesJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_valuesJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {fingerprint};
  @override
  DeviceLocalSettingsLedgerRow map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceLocalSettingsLedgerRow(
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
      deviceName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_name'],
      )!,
      platform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}platform'],
      )!,
      savedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}saved_at_utc'],
      )!,
      valuesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}values_json'],
      )!,
    );
  }

  @override
  $DeviceLocalSettingsLedgerRowsTable createAlias(String alias) {
    return $DeviceLocalSettingsLedgerRowsTable(attachedDatabase, alias);
  }
}

class DeviceLocalSettingsLedgerRow extends DataClass
    implements Insertable<DeviceLocalSettingsLedgerRow> {
  /// 设备指纹散列（sha256 前 32 位十六进制字符）。
  final String fingerprint;

  /// 仅用于显示的设备名（电脑名称 / 手机型号）。
  final String deviceName;

  /// 平台短名：windows / macos / linux / android / ios。
  final String platform;

  /// 该记录代表的本机设置取值时刻（UTC）。
  final DateTime savedAtUtc;

  /// 10 个本机设置键的取值，JSON 对象；键序与内容由采集侧保证。
  final String valuesJson;
  const DeviceLocalSettingsLedgerRow({
    required this.fingerprint,
    required this.deviceName,
    required this.platform,
    required this.savedAtUtc,
    required this.valuesJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['fingerprint'] = Variable<String>(fingerprint);
    map['device_name'] = Variable<String>(deviceName);
    map['platform'] = Variable<String>(platform);
    map['saved_at_utc'] = Variable<DateTime>(savedAtUtc);
    map['values_json'] = Variable<String>(valuesJson);
    return map;
  }

  DeviceLocalSettingsLedgerRowsCompanion toCompanion(bool nullToAbsent) {
    return DeviceLocalSettingsLedgerRowsCompanion(
      fingerprint: Value(fingerprint),
      deviceName: Value(deviceName),
      platform: Value(platform),
      savedAtUtc: Value(savedAtUtc),
      valuesJson: Value(valuesJson),
    );
  }

  factory DeviceLocalSettingsLedgerRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceLocalSettingsLedgerRow(
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      deviceName: serializer.fromJson<String>(json['deviceName']),
      platform: serializer.fromJson<String>(json['platform']),
      savedAtUtc: serializer.fromJson<DateTime>(json['savedAtUtc']),
      valuesJson: serializer.fromJson<String>(json['valuesJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'fingerprint': serializer.toJson<String>(fingerprint),
      'deviceName': serializer.toJson<String>(deviceName),
      'platform': serializer.toJson<String>(platform),
      'savedAtUtc': serializer.toJson<DateTime>(savedAtUtc),
      'valuesJson': serializer.toJson<String>(valuesJson),
    };
  }

  DeviceLocalSettingsLedgerRow copyWith({
    String? fingerprint,
    String? deviceName,
    String? platform,
    DateTime? savedAtUtc,
    String? valuesJson,
  }) => DeviceLocalSettingsLedgerRow(
    fingerprint: fingerprint ?? this.fingerprint,
    deviceName: deviceName ?? this.deviceName,
    platform: platform ?? this.platform,
    savedAtUtc: savedAtUtc ?? this.savedAtUtc,
    valuesJson: valuesJson ?? this.valuesJson,
  );
  DeviceLocalSettingsLedgerRow copyWithCompanion(
    DeviceLocalSettingsLedgerRowsCompanion data,
  ) {
    return DeviceLocalSettingsLedgerRow(
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      deviceName: data.deviceName.present
          ? data.deviceName.value
          : this.deviceName,
      platform: data.platform.present ? data.platform.value : this.platform,
      savedAtUtc: data.savedAtUtc.present
          ? data.savedAtUtc.value
          : this.savedAtUtc,
      valuesJson: data.valuesJson.present
          ? data.valuesJson.value
          : this.valuesJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceLocalSettingsLedgerRow(')
          ..write('fingerprint: $fingerprint, ')
          ..write('deviceName: $deviceName, ')
          ..write('platform: $platform, ')
          ..write('savedAtUtc: $savedAtUtc, ')
          ..write('valuesJson: $valuesJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(fingerprint, deviceName, platform, savedAtUtc, valuesJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceLocalSettingsLedgerRow &&
          other.fingerprint == this.fingerprint &&
          other.deviceName == this.deviceName &&
          other.platform == this.platform &&
          other.savedAtUtc == this.savedAtUtc &&
          other.valuesJson == this.valuesJson);
}

class DeviceLocalSettingsLedgerRowsCompanion
    extends UpdateCompanion<DeviceLocalSettingsLedgerRow> {
  final Value<String> fingerprint;
  final Value<String> deviceName;
  final Value<String> platform;
  final Value<DateTime> savedAtUtc;
  final Value<String> valuesJson;
  final Value<int> rowid;
  const DeviceLocalSettingsLedgerRowsCompanion({
    this.fingerprint = const Value.absent(),
    this.deviceName = const Value.absent(),
    this.platform = const Value.absent(),
    this.savedAtUtc = const Value.absent(),
    this.valuesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeviceLocalSettingsLedgerRowsCompanion.insert({
    required String fingerprint,
    required String deviceName,
    required String platform,
    required DateTime savedAtUtc,
    required String valuesJson,
    this.rowid = const Value.absent(),
  }) : fingerprint = Value(fingerprint),
       deviceName = Value(deviceName),
       platform = Value(platform),
       savedAtUtc = Value(savedAtUtc),
       valuesJson = Value(valuesJson);
  static Insertable<DeviceLocalSettingsLedgerRow> custom({
    Expression<String>? fingerprint,
    Expression<String>? deviceName,
    Expression<String>? platform,
    Expression<DateTime>? savedAtUtc,
    Expression<String>? valuesJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (deviceName != null) 'device_name': deviceName,
      if (platform != null) 'platform': platform,
      if (savedAtUtc != null) 'saved_at_utc': savedAtUtc,
      if (valuesJson != null) 'values_json': valuesJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeviceLocalSettingsLedgerRowsCompanion copyWith({
    Value<String>? fingerprint,
    Value<String>? deviceName,
    Value<String>? platform,
    Value<DateTime>? savedAtUtc,
    Value<String>? valuesJson,
    Value<int>? rowid,
  }) {
    return DeviceLocalSettingsLedgerRowsCompanion(
      fingerprint: fingerprint ?? this.fingerprint,
      deviceName: deviceName ?? this.deviceName,
      platform: platform ?? this.platform,
      savedAtUtc: savedAtUtc ?? this.savedAtUtc,
      valuesJson: valuesJson ?? this.valuesJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (deviceName.present) {
      map['device_name'] = Variable<String>(deviceName.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (savedAtUtc.present) {
      map['saved_at_utc'] = Variable<DateTime>(savedAtUtc.value);
    }
    if (valuesJson.present) {
      map['values_json'] = Variable<String>(valuesJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeviceLocalSettingsLedgerRowsCompanion(')
          ..write('fingerprint: $fingerprint, ')
          ..write('deviceName: $deviceName, ')
          ..write('platform: $platform, ')
          ..write('savedAtUtc: $savedAtUtc, ')
          ..write('valuesJson: $valuesJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeviceLedgerStateRowsTable extends DeviceLedgerStateRows
    with TableInfo<$DeviceLedgerStateRowsTable, DeviceLedgerStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeviceLedgerStateRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'device_ledger_state_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeviceLedgerStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  DeviceLedgerStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceLedgerStateRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $DeviceLedgerStateRowsTable createAlias(String alias) {
    return $DeviceLedgerStateRowsTable(attachedDatabase, alias);
  }
}

class DeviceLedgerStateRow extends DataClass
    implements Insertable<DeviceLedgerStateRow> {
  /// 状态键。
  final String key;

  /// 状态值（如 run id）。
  final String value;
  const DeviceLedgerStateRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  DeviceLedgerStateRowsCompanion toCompanion(bool nullToAbsent) {
    return DeviceLedgerStateRowsCompanion(key: Value(key), value: Value(value));
  }

  factory DeviceLedgerStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceLedgerStateRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  DeviceLedgerStateRow copyWith({String? key, String? value}) =>
      DeviceLedgerStateRow(key: key ?? this.key, value: value ?? this.value);
  DeviceLedgerStateRow copyWithCompanion(DeviceLedgerStateRowsCompanion data) {
    return DeviceLedgerStateRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceLedgerStateRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceLedgerStateRow &&
          other.key == this.key &&
          other.value == this.value);
}

class DeviceLedgerStateRowsCompanion
    extends UpdateCompanion<DeviceLedgerStateRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const DeviceLedgerStateRowsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeviceLedgerStateRowsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<DeviceLedgerStateRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeviceLedgerStateRowsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return DeviceLedgerStateRowsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeviceLedgerStateRowsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$DeviceLedgerDatabase extends GeneratedDatabase {
  _$DeviceLedgerDatabase(QueryExecutor e) : super(e);
  $DeviceLedgerDatabaseManager get managers =>
      $DeviceLedgerDatabaseManager(this);
  late final $DeviceLocalSettingsLedgerRowsTable deviceLocalSettingsLedgerRows =
      $DeviceLocalSettingsLedgerRowsTable(this);
  late final $DeviceLedgerStateRowsTable deviceLedgerStateRows =
      $DeviceLedgerStateRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    deviceLocalSettingsLedgerRows,
    deviceLedgerStateRows,
  ];
}

typedef $$DeviceLocalSettingsLedgerRowsTableCreateCompanionBuilder =
    DeviceLocalSettingsLedgerRowsCompanion Function({
      required String fingerprint,
      required String deviceName,
      required String platform,
      required DateTime savedAtUtc,
      required String valuesJson,
      Value<int> rowid,
    });
typedef $$DeviceLocalSettingsLedgerRowsTableUpdateCompanionBuilder =
    DeviceLocalSettingsLedgerRowsCompanion Function({
      Value<String> fingerprint,
      Value<String> deviceName,
      Value<String> platform,
      Value<DateTime> savedAtUtc,
      Value<String> valuesJson,
      Value<int> rowid,
    });

class $$DeviceLocalSettingsLedgerRowsTableFilterComposer
    extends
        Composer<_$DeviceLedgerDatabase, $DeviceLocalSettingsLedgerRowsTable> {
  $$DeviceLocalSettingsLedgerRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceName => $composableBuilder(
    column: $table.deviceName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get savedAtUtc => $composableBuilder(
    column: $table.savedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get valuesJson => $composableBuilder(
    column: $table.valuesJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DeviceLocalSettingsLedgerRowsTableOrderingComposer
    extends
        Composer<_$DeviceLedgerDatabase, $DeviceLocalSettingsLedgerRowsTable> {
  $$DeviceLocalSettingsLedgerRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceName => $composableBuilder(
    column: $table.deviceName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get savedAtUtc => $composableBuilder(
    column: $table.savedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get valuesJson => $composableBuilder(
    column: $table.valuesJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DeviceLocalSettingsLedgerRowsTableAnnotationComposer
    extends
        Composer<_$DeviceLedgerDatabase, $DeviceLocalSettingsLedgerRowsTable> {
  $$DeviceLocalSettingsLedgerRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deviceName => $composableBuilder(
    column: $table.deviceName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get platform =>
      $composableBuilder(column: $table.platform, builder: (column) => column);

  GeneratedColumn<DateTime> get savedAtUtc => $composableBuilder(
    column: $table.savedAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<String> get valuesJson => $composableBuilder(
    column: $table.valuesJson,
    builder: (column) => column,
  );
}

class $$DeviceLocalSettingsLedgerRowsTableTableManager
    extends
        RootTableManager<
          _$DeviceLedgerDatabase,
          $DeviceLocalSettingsLedgerRowsTable,
          DeviceLocalSettingsLedgerRow,
          $$DeviceLocalSettingsLedgerRowsTableFilterComposer,
          $$DeviceLocalSettingsLedgerRowsTableOrderingComposer,
          $$DeviceLocalSettingsLedgerRowsTableAnnotationComposer,
          $$DeviceLocalSettingsLedgerRowsTableCreateCompanionBuilder,
          $$DeviceLocalSettingsLedgerRowsTableUpdateCompanionBuilder,
          (
            DeviceLocalSettingsLedgerRow,
            BaseReferences<
              _$DeviceLedgerDatabase,
              $DeviceLocalSettingsLedgerRowsTable,
              DeviceLocalSettingsLedgerRow
            >,
          ),
          DeviceLocalSettingsLedgerRow,
          PrefetchHooks Function()
        > {
  $$DeviceLocalSettingsLedgerRowsTableTableManager(
    _$DeviceLedgerDatabase db,
    $DeviceLocalSettingsLedgerRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeviceLocalSettingsLedgerRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$DeviceLocalSettingsLedgerRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$DeviceLocalSettingsLedgerRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> fingerprint = const Value.absent(),
                Value<String> deviceName = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<DateTime> savedAtUtc = const Value.absent(),
                Value<String> valuesJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DeviceLocalSettingsLedgerRowsCompanion(
                fingerprint: fingerprint,
                deviceName: deviceName,
                platform: platform,
                savedAtUtc: savedAtUtc,
                valuesJson: valuesJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String fingerprint,
                required String deviceName,
                required String platform,
                required DateTime savedAtUtc,
                required String valuesJson,
                Value<int> rowid = const Value.absent(),
              }) => DeviceLocalSettingsLedgerRowsCompanion.insert(
                fingerprint: fingerprint,
                deviceName: deviceName,
                platform: platform,
                savedAtUtc: savedAtUtc,
                valuesJson: valuesJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DeviceLocalSettingsLedgerRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$DeviceLedgerDatabase,
      $DeviceLocalSettingsLedgerRowsTable,
      DeviceLocalSettingsLedgerRow,
      $$DeviceLocalSettingsLedgerRowsTableFilterComposer,
      $$DeviceLocalSettingsLedgerRowsTableOrderingComposer,
      $$DeviceLocalSettingsLedgerRowsTableAnnotationComposer,
      $$DeviceLocalSettingsLedgerRowsTableCreateCompanionBuilder,
      $$DeviceLocalSettingsLedgerRowsTableUpdateCompanionBuilder,
      (
        DeviceLocalSettingsLedgerRow,
        BaseReferences<
          _$DeviceLedgerDatabase,
          $DeviceLocalSettingsLedgerRowsTable,
          DeviceLocalSettingsLedgerRow
        >,
      ),
      DeviceLocalSettingsLedgerRow,
      PrefetchHooks Function()
    >;
typedef $$DeviceLedgerStateRowsTableCreateCompanionBuilder =
    DeviceLedgerStateRowsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$DeviceLedgerStateRowsTableUpdateCompanionBuilder =
    DeviceLedgerStateRowsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$DeviceLedgerStateRowsTableFilterComposer
    extends Composer<_$DeviceLedgerDatabase, $DeviceLedgerStateRowsTable> {
  $$DeviceLedgerStateRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DeviceLedgerStateRowsTableOrderingComposer
    extends Composer<_$DeviceLedgerDatabase, $DeviceLedgerStateRowsTable> {
  $$DeviceLedgerStateRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DeviceLedgerStateRowsTableAnnotationComposer
    extends Composer<_$DeviceLedgerDatabase, $DeviceLedgerStateRowsTable> {
  $$DeviceLedgerStateRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$DeviceLedgerStateRowsTableTableManager
    extends
        RootTableManager<
          _$DeviceLedgerDatabase,
          $DeviceLedgerStateRowsTable,
          DeviceLedgerStateRow,
          $$DeviceLedgerStateRowsTableFilterComposer,
          $$DeviceLedgerStateRowsTableOrderingComposer,
          $$DeviceLedgerStateRowsTableAnnotationComposer,
          $$DeviceLedgerStateRowsTableCreateCompanionBuilder,
          $$DeviceLedgerStateRowsTableUpdateCompanionBuilder,
          (
            DeviceLedgerStateRow,
            BaseReferences<
              _$DeviceLedgerDatabase,
              $DeviceLedgerStateRowsTable,
              DeviceLedgerStateRow
            >,
          ),
          DeviceLedgerStateRow,
          PrefetchHooks Function()
        > {
  $$DeviceLedgerStateRowsTableTableManager(
    _$DeviceLedgerDatabase db,
    $DeviceLedgerStateRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeviceLedgerStateRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$DeviceLedgerStateRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$DeviceLedgerStateRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DeviceLedgerStateRowsCompanion(
                key: key,
                value: value,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => DeviceLedgerStateRowsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DeviceLedgerStateRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$DeviceLedgerDatabase,
      $DeviceLedgerStateRowsTable,
      DeviceLedgerStateRow,
      $$DeviceLedgerStateRowsTableFilterComposer,
      $$DeviceLedgerStateRowsTableOrderingComposer,
      $$DeviceLedgerStateRowsTableAnnotationComposer,
      $$DeviceLedgerStateRowsTableCreateCompanionBuilder,
      $$DeviceLedgerStateRowsTableUpdateCompanionBuilder,
      (
        DeviceLedgerStateRow,
        BaseReferences<
          _$DeviceLedgerDatabase,
          $DeviceLedgerStateRowsTable,
          DeviceLedgerStateRow
        >,
      ),
      DeviceLedgerStateRow,
      PrefetchHooks Function()
    >;

class $DeviceLedgerDatabaseManager {
  final _$DeviceLedgerDatabase _db;
  $DeviceLedgerDatabaseManager(this._db);
  $$DeviceLocalSettingsLedgerRowsTableTableManager
  get deviceLocalSettingsLedgerRows =>
      $$DeviceLocalSettingsLedgerRowsTableTableManager(
        _db,
        _db.deviceLocalSettingsLedgerRows,
      );
  $$DeviceLedgerStateRowsTableTableManager get deviceLedgerStateRows =>
      $$DeviceLedgerStateRowsTableTableManager(_db, _db.deviceLedgerStateRows);
}
