// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_db.dart';

// ignore_for_file: type=lint
class $EmpleadosTable extends Empleados
    with TableInfo<$EmpleadosTable, EmpleadoLocal> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EmpleadosTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codigoMeta = const VerificationMeta('codigo');
  @override
  late final GeneratedColumn<String> codigo = GeneratedColumn<String>(
    'codigo',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nombresMeta = const VerificationMeta(
    'nombres',
  );
  @override
  late final GeneratedColumn<String> nombres = GeneratedColumn<String>(
    'nombres',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _apellidosMeta = const VerificationMeta(
    'apellidos',
  );
  @override
  late final GeneratedColumn<String> apellidos = GeneratedColumn<String>(
    'apellidos',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _celulaIdMeta = const VerificationMeta(
    'celulaId',
  );
  @override
  late final GeneratedColumn<String> celulaId = GeneratedColumn<String>(
    'celula_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _qrMeta = const VerificationMeta('qr');
  @override
  late final GeneratedColumn<String> qr = GeneratedColumn<String>(
    'qr',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fotoPathMeta = const VerificationMeta(
    'fotoPath',
  );
  @override
  late final GeneratedColumn<String> fotoPath = GeneratedColumn<String>(
    'foto_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _activoMeta = const VerificationMeta('activo');
  @override
  late final GeneratedColumn<int> activo = GeneratedColumn<int>(
    'activo',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    codigo,
    nombres,
    apellidos,
    celulaId,
    qr,
    fotoPath,
    activo,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'empleados';
  @override
  VerificationContext validateIntegrity(
    Insertable<EmpleadoLocal> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('codigo')) {
      context.handle(
        _codigoMeta,
        codigo.isAcceptableOrUnknown(data['codigo']!, _codigoMeta),
      );
    }
    if (data.containsKey('nombres')) {
      context.handle(
        _nombresMeta,
        nombres.isAcceptableOrUnknown(data['nombres']!, _nombresMeta),
      );
    }
    if (data.containsKey('apellidos')) {
      context.handle(
        _apellidosMeta,
        apellidos.isAcceptableOrUnknown(data['apellidos']!, _apellidosMeta),
      );
    }
    if (data.containsKey('celula_id')) {
      context.handle(
        _celulaIdMeta,
        celulaId.isAcceptableOrUnknown(data['celula_id']!, _celulaIdMeta),
      );
    }
    if (data.containsKey('qr')) {
      context.handle(_qrMeta, qr.isAcceptableOrUnknown(data['qr']!, _qrMeta));
    }
    if (data.containsKey('foto_path')) {
      context.handle(
        _fotoPathMeta,
        fotoPath.isAcceptableOrUnknown(data['foto_path']!, _fotoPathMeta),
      );
    }
    if (data.containsKey('activo')) {
      context.handle(
        _activoMeta,
        activo.isAcceptableOrUnknown(data['activo']!, _activoMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EmpleadoLocal map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EmpleadoLocal(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      codigo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}codigo'],
      ),
      nombres: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nombres'],
      ),
      apellidos: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}apellidos'],
      ),
      celulaId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}celula_id'],
      ),
      qr: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}qr'],
      ),
      fotoPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}foto_path'],
      ),
      activo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}activo'],
      ),
    );
  }

  @override
  $EmpleadosTable createAlias(String alias) {
    return $EmpleadosTable(attachedDatabase, alias);
  }
}

class EmpleadoLocal extends DataClass implements Insertable<EmpleadoLocal> {
  final String id;
  final String? codigo;
  final String? nombres;
  final String? apellidos;
  final String? celulaId;
  final String? qr;
  final String? fotoPath;
  final int? activo;
  const EmpleadoLocal({
    required this.id,
    this.codigo,
    this.nombres,
    this.apellidos,
    this.celulaId,
    this.qr,
    this.fotoPath,
    this.activo,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || codigo != null) {
      map['codigo'] = Variable<String>(codigo);
    }
    if (!nullToAbsent || nombres != null) {
      map['nombres'] = Variable<String>(nombres);
    }
    if (!nullToAbsent || apellidos != null) {
      map['apellidos'] = Variable<String>(apellidos);
    }
    if (!nullToAbsent || celulaId != null) {
      map['celula_id'] = Variable<String>(celulaId);
    }
    if (!nullToAbsent || qr != null) {
      map['qr'] = Variable<String>(qr);
    }
    if (!nullToAbsent || fotoPath != null) {
      map['foto_path'] = Variable<String>(fotoPath);
    }
    if (!nullToAbsent || activo != null) {
      map['activo'] = Variable<int>(activo);
    }
    return map;
  }

  EmpleadosCompanion toCompanion(bool nullToAbsent) {
    return EmpleadosCompanion(
      id: Value(id),
      codigo: codigo == null && nullToAbsent
          ? const Value.absent()
          : Value(codigo),
      nombres: nombres == null && nullToAbsent
          ? const Value.absent()
          : Value(nombres),
      apellidos: apellidos == null && nullToAbsent
          ? const Value.absent()
          : Value(apellidos),
      celulaId: celulaId == null && nullToAbsent
          ? const Value.absent()
          : Value(celulaId),
      qr: qr == null && nullToAbsent ? const Value.absent() : Value(qr),
      fotoPath: fotoPath == null && nullToAbsent
          ? const Value.absent()
          : Value(fotoPath),
      activo: activo == null && nullToAbsent
          ? const Value.absent()
          : Value(activo),
    );
  }

  factory EmpleadoLocal.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EmpleadoLocal(
      id: serializer.fromJson<String>(json['id']),
      codigo: serializer.fromJson<String?>(json['codigo']),
      nombres: serializer.fromJson<String?>(json['nombres']),
      apellidos: serializer.fromJson<String?>(json['apellidos']),
      celulaId: serializer.fromJson<String?>(json['celulaId']),
      qr: serializer.fromJson<String?>(json['qr']),
      fotoPath: serializer.fromJson<String?>(json['fotoPath']),
      activo: serializer.fromJson<int?>(json['activo']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'codigo': serializer.toJson<String?>(codigo),
      'nombres': serializer.toJson<String?>(nombres),
      'apellidos': serializer.toJson<String?>(apellidos),
      'celulaId': serializer.toJson<String?>(celulaId),
      'qr': serializer.toJson<String?>(qr),
      'fotoPath': serializer.toJson<String?>(fotoPath),
      'activo': serializer.toJson<int?>(activo),
    };
  }

  EmpleadoLocal copyWith({
    String? id,
    Value<String?> codigo = const Value.absent(),
    Value<String?> nombres = const Value.absent(),
    Value<String?> apellidos = const Value.absent(),
    Value<String?> celulaId = const Value.absent(),
    Value<String?> qr = const Value.absent(),
    Value<String?> fotoPath = const Value.absent(),
    Value<int?> activo = const Value.absent(),
  }) => EmpleadoLocal(
    id: id ?? this.id,
    codigo: codigo.present ? codigo.value : this.codigo,
    nombres: nombres.present ? nombres.value : this.nombres,
    apellidos: apellidos.present ? apellidos.value : this.apellidos,
    celulaId: celulaId.present ? celulaId.value : this.celulaId,
    qr: qr.present ? qr.value : this.qr,
    fotoPath: fotoPath.present ? fotoPath.value : this.fotoPath,
    activo: activo.present ? activo.value : this.activo,
  );
  EmpleadoLocal copyWithCompanion(EmpleadosCompanion data) {
    return EmpleadoLocal(
      id: data.id.present ? data.id.value : this.id,
      codigo: data.codigo.present ? data.codigo.value : this.codigo,
      nombres: data.nombres.present ? data.nombres.value : this.nombres,
      apellidos: data.apellidos.present ? data.apellidos.value : this.apellidos,
      celulaId: data.celulaId.present ? data.celulaId.value : this.celulaId,
      qr: data.qr.present ? data.qr.value : this.qr,
      fotoPath: data.fotoPath.present ? data.fotoPath.value : this.fotoPath,
      activo: data.activo.present ? data.activo.value : this.activo,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EmpleadoLocal(')
          ..write('id: $id, ')
          ..write('codigo: $codigo, ')
          ..write('nombres: $nombres, ')
          ..write('apellidos: $apellidos, ')
          ..write('celulaId: $celulaId, ')
          ..write('qr: $qr, ')
          ..write('fotoPath: $fotoPath, ')
          ..write('activo: $activo')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    codigo,
    nombres,
    apellidos,
    celulaId,
    qr,
    fotoPath,
    activo,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EmpleadoLocal &&
          other.id == this.id &&
          other.codigo == this.codigo &&
          other.nombres == this.nombres &&
          other.apellidos == this.apellidos &&
          other.celulaId == this.celulaId &&
          other.qr == this.qr &&
          other.fotoPath == this.fotoPath &&
          other.activo == this.activo);
}

class EmpleadosCompanion extends UpdateCompanion<EmpleadoLocal> {
  final Value<String> id;
  final Value<String?> codigo;
  final Value<String?> nombres;
  final Value<String?> apellidos;
  final Value<String?> celulaId;
  final Value<String?> qr;
  final Value<String?> fotoPath;
  final Value<int?> activo;
  final Value<int> rowid;
  const EmpleadosCompanion({
    this.id = const Value.absent(),
    this.codigo = const Value.absent(),
    this.nombres = const Value.absent(),
    this.apellidos = const Value.absent(),
    this.celulaId = const Value.absent(),
    this.qr = const Value.absent(),
    this.fotoPath = const Value.absent(),
    this.activo = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EmpleadosCompanion.insert({
    required String id,
    this.codigo = const Value.absent(),
    this.nombres = const Value.absent(),
    this.apellidos = const Value.absent(),
    this.celulaId = const Value.absent(),
    this.qr = const Value.absent(),
    this.fotoPath = const Value.absent(),
    this.activo = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id);
  static Insertable<EmpleadoLocal> custom({
    Expression<String>? id,
    Expression<String>? codigo,
    Expression<String>? nombres,
    Expression<String>? apellidos,
    Expression<String>? celulaId,
    Expression<String>? qr,
    Expression<String>? fotoPath,
    Expression<int>? activo,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (codigo != null) 'codigo': codigo,
      if (nombres != null) 'nombres': nombres,
      if (apellidos != null) 'apellidos': apellidos,
      if (celulaId != null) 'celula_id': celulaId,
      if (qr != null) 'qr': qr,
      if (fotoPath != null) 'foto_path': fotoPath,
      if (activo != null) 'activo': activo,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EmpleadosCompanion copyWith({
    Value<String>? id,
    Value<String?>? codigo,
    Value<String?>? nombres,
    Value<String?>? apellidos,
    Value<String?>? celulaId,
    Value<String?>? qr,
    Value<String?>? fotoPath,
    Value<int?>? activo,
    Value<int>? rowid,
  }) {
    return EmpleadosCompanion(
      id: id ?? this.id,
      codigo: codigo ?? this.codigo,
      nombres: nombres ?? this.nombres,
      apellidos: apellidos ?? this.apellidos,
      celulaId: celulaId ?? this.celulaId,
      qr: qr ?? this.qr,
      fotoPath: fotoPath ?? this.fotoPath,
      activo: activo ?? this.activo,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (codigo.present) {
      map['codigo'] = Variable<String>(codigo.value);
    }
    if (nombres.present) {
      map['nombres'] = Variable<String>(nombres.value);
    }
    if (apellidos.present) {
      map['apellidos'] = Variable<String>(apellidos.value);
    }
    if (celulaId.present) {
      map['celula_id'] = Variable<String>(celulaId.value);
    }
    if (qr.present) {
      map['qr'] = Variable<String>(qr.value);
    }
    if (fotoPath.present) {
      map['foto_path'] = Variable<String>(fotoPath.value);
    }
    if (activo.present) {
      map['activo'] = Variable<int>(activo.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EmpleadosCompanion(')
          ..write('id: $id, ')
          ..write('codigo: $codigo, ')
          ..write('nombres: $nombres, ')
          ..write('apellidos: $apellidos, ')
          ..write('celulaId: $celulaId, ')
          ..write('qr: $qr, ')
          ..write('fotoPath: $fotoPath, ')
          ..write('activo: $activo, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $EstacionesTable extends Estaciones
    with TableInfo<$EstacionesTable, EstacionLocal> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EstacionesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codigoMeta = const VerificationMeta('codigo');
  @override
  late final GeneratedColumn<String> codigo = GeneratedColumn<String>(
    'codigo',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nombreMeta = const VerificationMeta('nombre');
  @override
  late final GeneratedColumn<String> nombre = GeneratedColumn<String>(
    'nombre',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tipoMeta = const VerificationMeta('tipo');
  @override
  late final GeneratedColumn<String> tipo = GeneratedColumn<String>(
    'tipo',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _procesoMeta = const VerificationMeta(
    'proceso',
  );
  @override
  late final GeneratedColumn<String> proceso = GeneratedColumn<String>(
    'proceso',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _celulaIdMeta = const VerificationMeta(
    'celulaId',
  );
  @override
  late final GeneratedColumn<String> celulaId = GeneratedColumn<String>(
    'celula_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    codigo,
    nombre,
    tipo,
    proceso,
    celulaId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'estaciones';
  @override
  VerificationContext validateIntegrity(
    Insertable<EstacionLocal> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('codigo')) {
      context.handle(
        _codigoMeta,
        codigo.isAcceptableOrUnknown(data['codigo']!, _codigoMeta),
      );
    }
    if (data.containsKey('nombre')) {
      context.handle(
        _nombreMeta,
        nombre.isAcceptableOrUnknown(data['nombre']!, _nombreMeta),
      );
    }
    if (data.containsKey('tipo')) {
      context.handle(
        _tipoMeta,
        tipo.isAcceptableOrUnknown(data['tipo']!, _tipoMeta),
      );
    }
    if (data.containsKey('proceso')) {
      context.handle(
        _procesoMeta,
        proceso.isAcceptableOrUnknown(data['proceso']!, _procesoMeta),
      );
    }
    if (data.containsKey('celula_id')) {
      context.handle(
        _celulaIdMeta,
        celulaId.isAcceptableOrUnknown(data['celula_id']!, _celulaIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EstacionLocal map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EstacionLocal(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      codigo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}codigo'],
      ),
      nombre: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nombre'],
      ),
      tipo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tipo'],
      ),
      proceso: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proceso'],
      ),
      celulaId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}celula_id'],
      ),
    );
  }

  @override
  $EstacionesTable createAlias(String alias) {
    return $EstacionesTable(attachedDatabase, alias);
  }
}

class EstacionLocal extends DataClass implements Insertable<EstacionLocal> {
  final String id;
  final String? codigo;
  final String? nombre;
  final String? tipo;
  final String? proceso;
  final String? celulaId;
  const EstacionLocal({
    required this.id,
    this.codigo,
    this.nombre,
    this.tipo,
    this.proceso,
    this.celulaId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || codigo != null) {
      map['codigo'] = Variable<String>(codigo);
    }
    if (!nullToAbsent || nombre != null) {
      map['nombre'] = Variable<String>(nombre);
    }
    if (!nullToAbsent || tipo != null) {
      map['tipo'] = Variable<String>(tipo);
    }
    if (!nullToAbsent || proceso != null) {
      map['proceso'] = Variable<String>(proceso);
    }
    if (!nullToAbsent || celulaId != null) {
      map['celula_id'] = Variable<String>(celulaId);
    }
    return map;
  }

  EstacionesCompanion toCompanion(bool nullToAbsent) {
    return EstacionesCompanion(
      id: Value(id),
      codigo: codigo == null && nullToAbsent
          ? const Value.absent()
          : Value(codigo),
      nombre: nombre == null && nullToAbsent
          ? const Value.absent()
          : Value(nombre),
      tipo: tipo == null && nullToAbsent ? const Value.absent() : Value(tipo),
      proceso: proceso == null && nullToAbsent
          ? const Value.absent()
          : Value(proceso),
      celulaId: celulaId == null && nullToAbsent
          ? const Value.absent()
          : Value(celulaId),
    );
  }

  factory EstacionLocal.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EstacionLocal(
      id: serializer.fromJson<String>(json['id']),
      codigo: serializer.fromJson<String?>(json['codigo']),
      nombre: serializer.fromJson<String?>(json['nombre']),
      tipo: serializer.fromJson<String?>(json['tipo']),
      proceso: serializer.fromJson<String?>(json['proceso']),
      celulaId: serializer.fromJson<String?>(json['celulaId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'codigo': serializer.toJson<String?>(codigo),
      'nombre': serializer.toJson<String?>(nombre),
      'tipo': serializer.toJson<String?>(tipo),
      'proceso': serializer.toJson<String?>(proceso),
      'celulaId': serializer.toJson<String?>(celulaId),
    };
  }

  EstacionLocal copyWith({
    String? id,
    Value<String?> codigo = const Value.absent(),
    Value<String?> nombre = const Value.absent(),
    Value<String?> tipo = const Value.absent(),
    Value<String?> proceso = const Value.absent(),
    Value<String?> celulaId = const Value.absent(),
  }) => EstacionLocal(
    id: id ?? this.id,
    codigo: codigo.present ? codigo.value : this.codigo,
    nombre: nombre.present ? nombre.value : this.nombre,
    tipo: tipo.present ? tipo.value : this.tipo,
    proceso: proceso.present ? proceso.value : this.proceso,
    celulaId: celulaId.present ? celulaId.value : this.celulaId,
  );
  EstacionLocal copyWithCompanion(EstacionesCompanion data) {
    return EstacionLocal(
      id: data.id.present ? data.id.value : this.id,
      codigo: data.codigo.present ? data.codigo.value : this.codigo,
      nombre: data.nombre.present ? data.nombre.value : this.nombre,
      tipo: data.tipo.present ? data.tipo.value : this.tipo,
      proceso: data.proceso.present ? data.proceso.value : this.proceso,
      celulaId: data.celulaId.present ? data.celulaId.value : this.celulaId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EstacionLocal(')
          ..write('id: $id, ')
          ..write('codigo: $codigo, ')
          ..write('nombre: $nombre, ')
          ..write('tipo: $tipo, ')
          ..write('proceso: $proceso, ')
          ..write('celulaId: $celulaId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, codigo, nombre, tipo, proceso, celulaId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EstacionLocal &&
          other.id == this.id &&
          other.codigo == this.codigo &&
          other.nombre == this.nombre &&
          other.tipo == this.tipo &&
          other.proceso == this.proceso &&
          other.celulaId == this.celulaId);
}

class EstacionesCompanion extends UpdateCompanion<EstacionLocal> {
  final Value<String> id;
  final Value<String?> codigo;
  final Value<String?> nombre;
  final Value<String?> tipo;
  final Value<String?> proceso;
  final Value<String?> celulaId;
  final Value<int> rowid;
  const EstacionesCompanion({
    this.id = const Value.absent(),
    this.codigo = const Value.absent(),
    this.nombre = const Value.absent(),
    this.tipo = const Value.absent(),
    this.proceso = const Value.absent(),
    this.celulaId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EstacionesCompanion.insert({
    required String id,
    this.codigo = const Value.absent(),
    this.nombre = const Value.absent(),
    this.tipo = const Value.absent(),
    this.proceso = const Value.absent(),
    this.celulaId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id);
  static Insertable<EstacionLocal> custom({
    Expression<String>? id,
    Expression<String>? codigo,
    Expression<String>? nombre,
    Expression<String>? tipo,
    Expression<String>? proceso,
    Expression<String>? celulaId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (codigo != null) 'codigo': codigo,
      if (nombre != null) 'nombre': nombre,
      if (tipo != null) 'tipo': tipo,
      if (proceso != null) 'proceso': proceso,
      if (celulaId != null) 'celula_id': celulaId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EstacionesCompanion copyWith({
    Value<String>? id,
    Value<String?>? codigo,
    Value<String?>? nombre,
    Value<String?>? tipo,
    Value<String?>? proceso,
    Value<String?>? celulaId,
    Value<int>? rowid,
  }) {
    return EstacionesCompanion(
      id: id ?? this.id,
      codigo: codigo ?? this.codigo,
      nombre: nombre ?? this.nombre,
      tipo: tipo ?? this.tipo,
      proceso: proceso ?? this.proceso,
      celulaId: celulaId ?? this.celulaId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (codigo.present) {
      map['codigo'] = Variable<String>(codigo.value);
    }
    if (nombre.present) {
      map['nombre'] = Variable<String>(nombre.value);
    }
    if (tipo.present) {
      map['tipo'] = Variable<String>(tipo.value);
    }
    if (proceso.present) {
      map['proceso'] = Variable<String>(proceso.value);
    }
    if (celulaId.present) {
      map['celula_id'] = Variable<String>(celulaId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EstacionesCompanion(')
          ..write('id: $id, ')
          ..write('codigo: $codigo, ')
          ..write('nombre: $nombre, ')
          ..write('tipo: $tipo, ')
          ..write('proceso: $proceso, ')
          ..write('celulaId: $celulaId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BandejaEventosTable extends BandejaEventos
    with TableInfo<$BandejaEventosTable, EventoBandeja> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BandejaEventosTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tablaMeta = const VerificationMeta('tabla');
  @override
  late final GeneratedColumn<String> tabla = GeneratedColumn<String>(
    'tabla',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _estadoMeta = const VerificationMeta('estado');
  @override
  late final GeneratedColumn<String> estado = GeneratedColumn<String>(
    'estado',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resumenMeta = const VerificationMeta(
    'resumen',
  );
  @override
  late final GeneratedColumn<String> resumen = GeneratedColumn<String>(
    'resumen',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _empleadoIdMeta = const VerificationMeta(
    'empleadoId',
  );
  @override
  late final GeneratedColumn<String> empleadoId = GeneratedColumn<String>(
    'empleado_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ocurridoEnMeta = const VerificationMeta(
    'ocurridoEn',
  );
  @override
  late final GeneratedColumn<String> ocurridoEn = GeneratedColumn<String>(
    'ocurrido_en',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sincronizadoEnMeta = const VerificationMeta(
    'sincronizadoEn',
  );
  @override
  late final GeneratedColumn<String> sincronizadoEn = GeneratedColumn<String>(
    'sincronizado_en',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _motivoMeta = const VerificationMeta('motivo');
  @override
  late final GeneratedColumn<String> motivo = GeneratedColumn<String>(
    'motivo',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _intentosMeta = const VerificationMeta(
    'intentos',
  );
  @override
  late final GeneratedColumn<int> intentos = GeneratedColumn<int>(
    'intentos',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    tabla,
    estado,
    resumen,
    empleadoId,
    ocurridoEn,
    sincronizadoEn,
    motivo,
    intentos,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bandeja';
  @override
  VerificationContext validateIntegrity(
    Insertable<EventoBandeja> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('tabla')) {
      context.handle(
        _tablaMeta,
        tabla.isAcceptableOrUnknown(data['tabla']!, _tablaMeta),
      );
    }
    if (data.containsKey('estado')) {
      context.handle(
        _estadoMeta,
        estado.isAcceptableOrUnknown(data['estado']!, _estadoMeta),
      );
    }
    if (data.containsKey('resumen')) {
      context.handle(
        _resumenMeta,
        resumen.isAcceptableOrUnknown(data['resumen']!, _resumenMeta),
      );
    }
    if (data.containsKey('empleado_id')) {
      context.handle(
        _empleadoIdMeta,
        empleadoId.isAcceptableOrUnknown(data['empleado_id']!, _empleadoIdMeta),
      );
    }
    if (data.containsKey('ocurrido_en')) {
      context.handle(
        _ocurridoEnMeta,
        ocurridoEn.isAcceptableOrUnknown(data['ocurrido_en']!, _ocurridoEnMeta),
      );
    }
    if (data.containsKey('sincronizado_en')) {
      context.handle(
        _sincronizadoEnMeta,
        sincronizadoEn.isAcceptableOrUnknown(
          data['sincronizado_en']!,
          _sincronizadoEnMeta,
        ),
      );
    }
    if (data.containsKey('motivo')) {
      context.handle(
        _motivoMeta,
        motivo.isAcceptableOrUnknown(data['motivo']!, _motivoMeta),
      );
    }
    if (data.containsKey('intentos')) {
      context.handle(
        _intentosMeta,
        intentos.isAcceptableOrUnknown(data['intentos']!, _intentosMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EventoBandeja map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EventoBandeja(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      tabla: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tabla'],
      ),
      estado: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}estado'],
      ),
      resumen: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resumen'],
      ),
      empleadoId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}empleado_id'],
      ),
      ocurridoEn: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ocurrido_en'],
      ),
      sincronizadoEn: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sincronizado_en'],
      ),
      motivo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}motivo'],
      ),
      intentos: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}intentos'],
      ),
    );
  }

  @override
  $BandejaEventosTable createAlias(String alias) {
    return $BandejaEventosTable(attachedDatabase, alias);
  }
}

class EventoBandeja extends DataClass implements Insertable<EventoBandeja> {
  final String id;
  final String? tabla;
  final String? estado;
  final String? resumen;
  final String? empleadoId;
  final String? ocurridoEn;
  final String? sincronizadoEn;
  final String? motivo;
  final int? intentos;
  const EventoBandeja({
    required this.id,
    this.tabla,
    this.estado,
    this.resumen,
    this.empleadoId,
    this.ocurridoEn,
    this.sincronizadoEn,
    this.motivo,
    this.intentos,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || tabla != null) {
      map['tabla'] = Variable<String>(tabla);
    }
    if (!nullToAbsent || estado != null) {
      map['estado'] = Variable<String>(estado);
    }
    if (!nullToAbsent || resumen != null) {
      map['resumen'] = Variable<String>(resumen);
    }
    if (!nullToAbsent || empleadoId != null) {
      map['empleado_id'] = Variable<String>(empleadoId);
    }
    if (!nullToAbsent || ocurridoEn != null) {
      map['ocurrido_en'] = Variable<String>(ocurridoEn);
    }
    if (!nullToAbsent || sincronizadoEn != null) {
      map['sincronizado_en'] = Variable<String>(sincronizadoEn);
    }
    if (!nullToAbsent || motivo != null) {
      map['motivo'] = Variable<String>(motivo);
    }
    if (!nullToAbsent || intentos != null) {
      map['intentos'] = Variable<int>(intentos);
    }
    return map;
  }

  BandejaEventosCompanion toCompanion(bool nullToAbsent) {
    return BandejaEventosCompanion(
      id: Value(id),
      tabla: tabla == null && nullToAbsent
          ? const Value.absent()
          : Value(tabla),
      estado: estado == null && nullToAbsent
          ? const Value.absent()
          : Value(estado),
      resumen: resumen == null && nullToAbsent
          ? const Value.absent()
          : Value(resumen),
      empleadoId: empleadoId == null && nullToAbsent
          ? const Value.absent()
          : Value(empleadoId),
      ocurridoEn: ocurridoEn == null && nullToAbsent
          ? const Value.absent()
          : Value(ocurridoEn),
      sincronizadoEn: sincronizadoEn == null && nullToAbsent
          ? const Value.absent()
          : Value(sincronizadoEn),
      motivo: motivo == null && nullToAbsent
          ? const Value.absent()
          : Value(motivo),
      intentos: intentos == null && nullToAbsent
          ? const Value.absent()
          : Value(intentos),
    );
  }

  factory EventoBandeja.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EventoBandeja(
      id: serializer.fromJson<String>(json['id']),
      tabla: serializer.fromJson<String?>(json['tabla']),
      estado: serializer.fromJson<String?>(json['estado']),
      resumen: serializer.fromJson<String?>(json['resumen']),
      empleadoId: serializer.fromJson<String?>(json['empleadoId']),
      ocurridoEn: serializer.fromJson<String?>(json['ocurridoEn']),
      sincronizadoEn: serializer.fromJson<String?>(json['sincronizadoEn']),
      motivo: serializer.fromJson<String?>(json['motivo']),
      intentos: serializer.fromJson<int?>(json['intentos']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'tabla': serializer.toJson<String?>(tabla),
      'estado': serializer.toJson<String?>(estado),
      'resumen': serializer.toJson<String?>(resumen),
      'empleadoId': serializer.toJson<String?>(empleadoId),
      'ocurridoEn': serializer.toJson<String?>(ocurridoEn),
      'sincronizadoEn': serializer.toJson<String?>(sincronizadoEn),
      'motivo': serializer.toJson<String?>(motivo),
      'intentos': serializer.toJson<int?>(intentos),
    };
  }

  EventoBandeja copyWith({
    String? id,
    Value<String?> tabla = const Value.absent(),
    Value<String?> estado = const Value.absent(),
    Value<String?> resumen = const Value.absent(),
    Value<String?> empleadoId = const Value.absent(),
    Value<String?> ocurridoEn = const Value.absent(),
    Value<String?> sincronizadoEn = const Value.absent(),
    Value<String?> motivo = const Value.absent(),
    Value<int?> intentos = const Value.absent(),
  }) => EventoBandeja(
    id: id ?? this.id,
    tabla: tabla.present ? tabla.value : this.tabla,
    estado: estado.present ? estado.value : this.estado,
    resumen: resumen.present ? resumen.value : this.resumen,
    empleadoId: empleadoId.present ? empleadoId.value : this.empleadoId,
    ocurridoEn: ocurridoEn.present ? ocurridoEn.value : this.ocurridoEn,
    sincronizadoEn: sincronizadoEn.present
        ? sincronizadoEn.value
        : this.sincronizadoEn,
    motivo: motivo.present ? motivo.value : this.motivo,
    intentos: intentos.present ? intentos.value : this.intentos,
  );
  EventoBandeja copyWithCompanion(BandejaEventosCompanion data) {
    return EventoBandeja(
      id: data.id.present ? data.id.value : this.id,
      tabla: data.tabla.present ? data.tabla.value : this.tabla,
      estado: data.estado.present ? data.estado.value : this.estado,
      resumen: data.resumen.present ? data.resumen.value : this.resumen,
      empleadoId: data.empleadoId.present
          ? data.empleadoId.value
          : this.empleadoId,
      ocurridoEn: data.ocurridoEn.present
          ? data.ocurridoEn.value
          : this.ocurridoEn,
      sincronizadoEn: data.sincronizadoEn.present
          ? data.sincronizadoEn.value
          : this.sincronizadoEn,
      motivo: data.motivo.present ? data.motivo.value : this.motivo,
      intentos: data.intentos.present ? data.intentos.value : this.intentos,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EventoBandeja(')
          ..write('id: $id, ')
          ..write('tabla: $tabla, ')
          ..write('estado: $estado, ')
          ..write('resumen: $resumen, ')
          ..write('empleadoId: $empleadoId, ')
          ..write('ocurridoEn: $ocurridoEn, ')
          ..write('sincronizadoEn: $sincronizadoEn, ')
          ..write('motivo: $motivo, ')
          ..write('intentos: $intentos')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    tabla,
    estado,
    resumen,
    empleadoId,
    ocurridoEn,
    sincronizadoEn,
    motivo,
    intentos,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EventoBandeja &&
          other.id == this.id &&
          other.tabla == this.tabla &&
          other.estado == this.estado &&
          other.resumen == this.resumen &&
          other.empleadoId == this.empleadoId &&
          other.ocurridoEn == this.ocurridoEn &&
          other.sincronizadoEn == this.sincronizadoEn &&
          other.motivo == this.motivo &&
          other.intentos == this.intentos);
}

class BandejaEventosCompanion extends UpdateCompanion<EventoBandeja> {
  final Value<String> id;
  final Value<String?> tabla;
  final Value<String?> estado;
  final Value<String?> resumen;
  final Value<String?> empleadoId;
  final Value<String?> ocurridoEn;
  final Value<String?> sincronizadoEn;
  final Value<String?> motivo;
  final Value<int?> intentos;
  final Value<int> rowid;
  const BandejaEventosCompanion({
    this.id = const Value.absent(),
    this.tabla = const Value.absent(),
    this.estado = const Value.absent(),
    this.resumen = const Value.absent(),
    this.empleadoId = const Value.absent(),
    this.ocurridoEn = const Value.absent(),
    this.sincronizadoEn = const Value.absent(),
    this.motivo = const Value.absent(),
    this.intentos = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BandejaEventosCompanion.insert({
    required String id,
    this.tabla = const Value.absent(),
    this.estado = const Value.absent(),
    this.resumen = const Value.absent(),
    this.empleadoId = const Value.absent(),
    this.ocurridoEn = const Value.absent(),
    this.sincronizadoEn = const Value.absent(),
    this.motivo = const Value.absent(),
    this.intentos = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id);
  static Insertable<EventoBandeja> custom({
    Expression<String>? id,
    Expression<String>? tabla,
    Expression<String>? estado,
    Expression<String>? resumen,
    Expression<String>? empleadoId,
    Expression<String>? ocurridoEn,
    Expression<String>? sincronizadoEn,
    Expression<String>? motivo,
    Expression<int>? intentos,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (tabla != null) 'tabla': tabla,
      if (estado != null) 'estado': estado,
      if (resumen != null) 'resumen': resumen,
      if (empleadoId != null) 'empleado_id': empleadoId,
      if (ocurridoEn != null) 'ocurrido_en': ocurridoEn,
      if (sincronizadoEn != null) 'sincronizado_en': sincronizadoEn,
      if (motivo != null) 'motivo': motivo,
      if (intentos != null) 'intentos': intentos,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BandejaEventosCompanion copyWith({
    Value<String>? id,
    Value<String?>? tabla,
    Value<String?>? estado,
    Value<String?>? resumen,
    Value<String?>? empleadoId,
    Value<String?>? ocurridoEn,
    Value<String?>? sincronizadoEn,
    Value<String?>? motivo,
    Value<int?>? intentos,
    Value<int>? rowid,
  }) {
    return BandejaEventosCompanion(
      id: id ?? this.id,
      tabla: tabla ?? this.tabla,
      estado: estado ?? this.estado,
      resumen: resumen ?? this.resumen,
      empleadoId: empleadoId ?? this.empleadoId,
      ocurridoEn: ocurridoEn ?? this.ocurridoEn,
      sincronizadoEn: sincronizadoEn ?? this.sincronizadoEn,
      motivo: motivo ?? this.motivo,
      intentos: intentos ?? this.intentos,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (tabla.present) {
      map['tabla'] = Variable<String>(tabla.value);
    }
    if (estado.present) {
      map['estado'] = Variable<String>(estado.value);
    }
    if (resumen.present) {
      map['resumen'] = Variable<String>(resumen.value);
    }
    if (empleadoId.present) {
      map['empleado_id'] = Variable<String>(empleadoId.value);
    }
    if (ocurridoEn.present) {
      map['ocurrido_en'] = Variable<String>(ocurridoEn.value);
    }
    if (sincronizadoEn.present) {
      map['sincronizado_en'] = Variable<String>(sincronizadoEn.value);
    }
    if (motivo.present) {
      map['motivo'] = Variable<String>(motivo.value);
    }
    if (intentos.present) {
      map['intentos'] = Variable<int>(intentos.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BandejaEventosCompanion(')
          ..write('id: $id, ')
          ..write('tabla: $tabla, ')
          ..write('estado: $estado, ')
          ..write('resumen: $resumen, ')
          ..write('empleadoId: $empleadoId, ')
          ..write('ocurridoEn: $ocurridoEn, ')
          ..write('sincronizadoEn: $sincronizadoEn, ')
          ..write('motivo: $motivo, ')
          ..write('intentos: $intentos, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDb extends GeneratedDatabase {
  _$AppDb(QueryExecutor e) : super(e);
  $AppDbManager get managers => $AppDbManager(this);
  late final $EmpleadosTable empleados = $EmpleadosTable(this);
  late final $EstacionesTable estaciones = $EstacionesTable(this);
  late final $BandejaEventosTable bandejaEventos = $BandejaEventosTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    empleados,
    estaciones,
    bandejaEventos,
  ];
}

typedef $$EmpleadosTableCreateCompanionBuilder = EmpleadosCompanion Function({
  required String id,
  Value<String?> codigo,
  Value<String?> nombres,
  Value<String?> apellidos,
  Value<String?> celulaId,
  Value<String?> qr,
  Value<String?> fotoPath,
  Value<int?> activo,
  Value<int> rowid,
});
typedef $$EmpleadosTableUpdateCompanionBuilder = EmpleadosCompanion Function({
  Value<String> id,
  Value<String?> codigo,
  Value<String?> nombres,
  Value<String?> apellidos,
  Value<String?> celulaId,
  Value<String?> qr,
  Value<String?> fotoPath,
  Value<int?> activo,
  Value<int> rowid,
});

class $$EmpleadosTableFilterComposer
    extends Composer<_$AppDb, $EmpleadosTable> {
  $$EmpleadosTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get codigo => $composableBuilder(
    column: $table.codigo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nombres => $composableBuilder(
    column: $table.nombres,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get apellidos => $composableBuilder(
    column: $table.apellidos,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get celulaId => $composableBuilder(
    column: $table.celulaId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get qr => $composableBuilder(
    column: $table.qr,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fotoPath => $composableBuilder(
    column: $table.fotoPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get activo => $composableBuilder(
    column: $table.activo,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EmpleadosTableOrderingComposer
    extends Composer<_$AppDb, $EmpleadosTable> {
  $$EmpleadosTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get codigo => $composableBuilder(
    column: $table.codigo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nombres => $composableBuilder(
    column: $table.nombres,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get apellidos => $composableBuilder(
    column: $table.apellidos,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get celulaId => $composableBuilder(
    column: $table.celulaId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get qr => $composableBuilder(
    column: $table.qr,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fotoPath => $composableBuilder(
    column: $table.fotoPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get activo => $composableBuilder(
    column: $table.activo,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EmpleadosTableAnnotationComposer
    extends Composer<_$AppDb, $EmpleadosTable> {
  $$EmpleadosTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get codigo =>
      $composableBuilder(column: $table.codigo, builder: (column) => column);

  GeneratedColumn<String> get nombres =>
      $composableBuilder(column: $table.nombres, builder: (column) => column);

  GeneratedColumn<String> get apellidos =>
      $composableBuilder(column: $table.apellidos, builder: (column) => column);

  GeneratedColumn<String> get celulaId =>
      $composableBuilder(column: $table.celulaId, builder: (column) => column);

  GeneratedColumn<String> get qr =>
      $composableBuilder(column: $table.qr, builder: (column) => column);

  GeneratedColumn<String> get fotoPath =>
      $composableBuilder(column: $table.fotoPath, builder: (column) => column);

  GeneratedColumn<int> get activo =>
      $composableBuilder(column: $table.activo, builder: (column) => column);
}

class $$EmpleadosTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $EmpleadosTable,
          EmpleadoLocal,
          $$EmpleadosTableFilterComposer,
          $$EmpleadosTableOrderingComposer,
          $$EmpleadosTableAnnotationComposer,
          $$EmpleadosTableCreateCompanionBuilder,
          $$EmpleadosTableUpdateCompanionBuilder,
          (
            EmpleadoLocal,
            BaseReferences<_$AppDb, $EmpleadosTable, EmpleadoLocal>,
          ),
          EmpleadoLocal,
          PrefetchHooks Function()
        > {
  $$EmpleadosTableTableManager(_$AppDb db, $EmpleadosTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EmpleadosTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EmpleadosTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EmpleadosTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> codigo = const Value.absent(),
                Value<String?> nombres = const Value.absent(),
                Value<String?> apellidos = const Value.absent(),
                Value<String?> celulaId = const Value.absent(),
                Value<String?> qr = const Value.absent(),
                Value<String?> fotoPath = const Value.absent(),
                Value<int?> activo = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EmpleadosCompanion(
                id: id,
                codigo: codigo,
                nombres: nombres,
                apellidos: apellidos,
                celulaId: celulaId,
                qr: qr,
                fotoPath: fotoPath,
                activo: activo,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> codigo = const Value.absent(),
                Value<String?> nombres = const Value.absent(),
                Value<String?> apellidos = const Value.absent(),
                Value<String?> celulaId = const Value.absent(),
                Value<String?> qr = const Value.absent(),
                Value<String?> fotoPath = const Value.absent(),
                Value<int?> activo = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EmpleadosCompanion.insert(
                id: id,
                codigo: codigo,
                nombres: nombres,
                apellidos: apellidos,
                celulaId: celulaId,
                qr: qr,
                fotoPath: fotoPath,
                activo: activo,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EmpleadosTable, EmpleadoLocal>(table),
                  BaseReferences<_$AppDb, $EmpleadosTable, EmpleadoLocal>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EmpleadosTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $EmpleadosTable,
      EmpleadoLocal,
      $$EmpleadosTableFilterComposer,
      $$EmpleadosTableOrderingComposer,
      $$EmpleadosTableAnnotationComposer,
      $$EmpleadosTableCreateCompanionBuilder,
      $$EmpleadosTableUpdateCompanionBuilder,
      (EmpleadoLocal, BaseReferences<_$AppDb, $EmpleadosTable, EmpleadoLocal>),
      EmpleadoLocal,
      PrefetchHooks Function()
    >;
typedef $$EstacionesTableCreateCompanionBuilder = EstacionesCompanion Function({
  required String id,
  Value<String?> codigo,
  Value<String?> nombre,
  Value<String?> tipo,
  Value<String?> proceso,
  Value<String?> celulaId,
  Value<int> rowid,
});
typedef $$EstacionesTableUpdateCompanionBuilder = EstacionesCompanion Function({
  Value<String> id,
  Value<String?> codigo,
  Value<String?> nombre,
  Value<String?> tipo,
  Value<String?> proceso,
  Value<String?> celulaId,
  Value<int> rowid,
});

class $$EstacionesTableFilterComposer
    extends Composer<_$AppDb, $EstacionesTable> {
  $$EstacionesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get codigo => $composableBuilder(
    column: $table.codigo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nombre => $composableBuilder(
    column: $table.nombre,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tipo => $composableBuilder(
    column: $table.tipo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proceso => $composableBuilder(
    column: $table.proceso,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get celulaId => $composableBuilder(
    column: $table.celulaId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EstacionesTableOrderingComposer
    extends Composer<_$AppDb, $EstacionesTable> {
  $$EstacionesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get codigo => $composableBuilder(
    column: $table.codigo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nombre => $composableBuilder(
    column: $table.nombre,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tipo => $composableBuilder(
    column: $table.tipo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proceso => $composableBuilder(
    column: $table.proceso,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get celulaId => $composableBuilder(
    column: $table.celulaId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EstacionesTableAnnotationComposer
    extends Composer<_$AppDb, $EstacionesTable> {
  $$EstacionesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get codigo =>
      $composableBuilder(column: $table.codigo, builder: (column) => column);

  GeneratedColumn<String> get nombre =>
      $composableBuilder(column: $table.nombre, builder: (column) => column);

  GeneratedColumn<String> get tipo =>
      $composableBuilder(column: $table.tipo, builder: (column) => column);

  GeneratedColumn<String> get proceso =>
      $composableBuilder(column: $table.proceso, builder: (column) => column);

  GeneratedColumn<String> get celulaId =>
      $composableBuilder(column: $table.celulaId, builder: (column) => column);
}

class $$EstacionesTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $EstacionesTable,
          EstacionLocal,
          $$EstacionesTableFilterComposer,
          $$EstacionesTableOrderingComposer,
          $$EstacionesTableAnnotationComposer,
          $$EstacionesTableCreateCompanionBuilder,
          $$EstacionesTableUpdateCompanionBuilder,
          (
            EstacionLocal,
            BaseReferences<_$AppDb, $EstacionesTable, EstacionLocal>,
          ),
          EstacionLocal,
          PrefetchHooks Function()
        > {
  $$EstacionesTableTableManager(_$AppDb db, $EstacionesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EstacionesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EstacionesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EstacionesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> codigo = const Value.absent(),
                Value<String?> nombre = const Value.absent(),
                Value<String?> tipo = const Value.absent(),
                Value<String?> proceso = const Value.absent(),
                Value<String?> celulaId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EstacionesCompanion(
                id: id,
                codigo: codigo,
                nombre: nombre,
                tipo: tipo,
                proceso: proceso,
                celulaId: celulaId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> codigo = const Value.absent(),
                Value<String?> nombre = const Value.absent(),
                Value<String?> tipo = const Value.absent(),
                Value<String?> proceso = const Value.absent(),
                Value<String?> celulaId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EstacionesCompanion.insert(
                id: id,
                codigo: codigo,
                nombre: nombre,
                tipo: tipo,
                proceso: proceso,
                celulaId: celulaId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EstacionesTable, EstacionLocal>(table),
                  BaseReferences<_$AppDb, $EstacionesTable, EstacionLocal>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EstacionesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $EstacionesTable,
      EstacionLocal,
      $$EstacionesTableFilterComposer,
      $$EstacionesTableOrderingComposer,
      $$EstacionesTableAnnotationComposer,
      $$EstacionesTableCreateCompanionBuilder,
      $$EstacionesTableUpdateCompanionBuilder,
      (EstacionLocal, BaseReferences<_$AppDb, $EstacionesTable, EstacionLocal>),
      EstacionLocal,
      PrefetchHooks Function()
    >;
typedef $$BandejaEventosTableCreateCompanionBuilder =
    BandejaEventosCompanion Function({
      required String id,
      Value<String?> tabla,
      Value<String?> estado,
      Value<String?> resumen,
      Value<String?> empleadoId,
      Value<String?> ocurridoEn,
      Value<String?> sincronizadoEn,
      Value<String?> motivo,
      Value<int?> intentos,
      Value<int> rowid,
    });
typedef $$BandejaEventosTableUpdateCompanionBuilder =
    BandejaEventosCompanion Function({
      Value<String> id,
      Value<String?> tabla,
      Value<String?> estado,
      Value<String?> resumen,
      Value<String?> empleadoId,
      Value<String?> ocurridoEn,
      Value<String?> sincronizadoEn,
      Value<String?> motivo,
      Value<int?> intentos,
      Value<int> rowid,
    });

class $$BandejaEventosTableFilterComposer
    extends Composer<_$AppDb, $BandejaEventosTable> {
  $$BandejaEventosTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tabla => $composableBuilder(
    column: $table.tabla,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get estado => $composableBuilder(
    column: $table.estado,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resumen => $composableBuilder(
    column: $table.resumen,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get empleadoId => $composableBuilder(
    column: $table.empleadoId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ocurridoEn => $composableBuilder(
    column: $table.ocurridoEn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sincronizadoEn => $composableBuilder(
    column: $table.sincronizadoEn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get motivo => $composableBuilder(
    column: $table.motivo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get intentos => $composableBuilder(
    column: $table.intentos,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BandejaEventosTableOrderingComposer
    extends Composer<_$AppDb, $BandejaEventosTable> {
  $$BandejaEventosTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tabla => $composableBuilder(
    column: $table.tabla,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get estado => $composableBuilder(
    column: $table.estado,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resumen => $composableBuilder(
    column: $table.resumen,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get empleadoId => $composableBuilder(
    column: $table.empleadoId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ocurridoEn => $composableBuilder(
    column: $table.ocurridoEn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sincronizadoEn => $composableBuilder(
    column: $table.sincronizadoEn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get motivo => $composableBuilder(
    column: $table.motivo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get intentos => $composableBuilder(
    column: $table.intentos,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BandejaEventosTableAnnotationComposer
    extends Composer<_$AppDb, $BandejaEventosTable> {
  $$BandejaEventosTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get tabla =>
      $composableBuilder(column: $table.tabla, builder: (column) => column);

  GeneratedColumn<String> get estado =>
      $composableBuilder(column: $table.estado, builder: (column) => column);

  GeneratedColumn<String> get resumen =>
      $composableBuilder(column: $table.resumen, builder: (column) => column);

  GeneratedColumn<String> get empleadoId => $composableBuilder(
    column: $table.empleadoId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ocurridoEn => $composableBuilder(
    column: $table.ocurridoEn,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sincronizadoEn => $composableBuilder(
    column: $table.sincronizadoEn,
    builder: (column) => column,
  );

  GeneratedColumn<String> get motivo =>
      $composableBuilder(column: $table.motivo, builder: (column) => column);

  GeneratedColumn<int> get intentos =>
      $composableBuilder(column: $table.intentos, builder: (column) => column);
}

class $$BandejaEventosTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $BandejaEventosTable,
          EventoBandeja,
          $$BandejaEventosTableFilterComposer,
          $$BandejaEventosTableOrderingComposer,
          $$BandejaEventosTableAnnotationComposer,
          $$BandejaEventosTableCreateCompanionBuilder,
          $$BandejaEventosTableUpdateCompanionBuilder,
          (
            EventoBandeja,
            BaseReferences<_$AppDb, $BandejaEventosTable, EventoBandeja>,
          ),
          EventoBandeja,
          PrefetchHooks Function()
        > {
  $$BandejaEventosTableTableManager(_$AppDb db, $BandejaEventosTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BandejaEventosTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BandejaEventosTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BandejaEventosTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> tabla = const Value.absent(),
                Value<String?> estado = const Value.absent(),
                Value<String?> resumen = const Value.absent(),
                Value<String?> empleadoId = const Value.absent(),
                Value<String?> ocurridoEn = const Value.absent(),
                Value<String?> sincronizadoEn = const Value.absent(),
                Value<String?> motivo = const Value.absent(),
                Value<int?> intentos = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BandejaEventosCompanion(
                id: id,
                tabla: tabla,
                estado: estado,
                resumen: resumen,
                empleadoId: empleadoId,
                ocurridoEn: ocurridoEn,
                sincronizadoEn: sincronizadoEn,
                motivo: motivo,
                intentos: intentos,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> tabla = const Value.absent(),
                Value<String?> estado = const Value.absent(),
                Value<String?> resumen = const Value.absent(),
                Value<String?> empleadoId = const Value.absent(),
                Value<String?> ocurridoEn = const Value.absent(),
                Value<String?> sincronizadoEn = const Value.absent(),
                Value<String?> motivo = const Value.absent(),
                Value<int?> intentos = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BandejaEventosCompanion.insert(
                id: id,
                tabla: tabla,
                estado: estado,
                resumen: resumen,
                empleadoId: empleadoId,
                ocurridoEn: ocurridoEn,
                sincronizadoEn: sincronizadoEn,
                motivo: motivo,
                intentos: intentos,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BandejaEventosTable, EventoBandeja>(table),
                  BaseReferences<_$AppDb, $BandejaEventosTable, EventoBandeja>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BandejaEventosTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $BandejaEventosTable,
      EventoBandeja,
      $$BandejaEventosTableFilterComposer,
      $$BandejaEventosTableOrderingComposer,
      $$BandejaEventosTableAnnotationComposer,
      $$BandejaEventosTableCreateCompanionBuilder,
      $$BandejaEventosTableUpdateCompanionBuilder,
      (
        EventoBandeja,
        BaseReferences<_$AppDb, $BandejaEventosTable, EventoBandeja>,
      ),
      EventoBandeja,
      PrefetchHooks Function()
    >;

class $AppDbManager {
  final _$AppDb _db;
  $AppDbManager(this._db);
  $$EmpleadosTableTableManager get empleados =>
      $$EmpleadosTableTableManager(_db, _db.empleados);
  $$EstacionesTableTableManager get estaciones =>
      $$EstacionesTableTableManager(_db, _db.estaciones);
  $$BandejaEventosTableTableManager get bandejaEventos =>
      $$BandejaEventosTableTableManager(_db, _db.bandejaEventos);
}
