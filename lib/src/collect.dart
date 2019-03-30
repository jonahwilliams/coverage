// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:vm_service_lib/vm_service_lib.dart';
import 'util.dart';

const _retryInterval = const Duration(milliseconds: 200);

Future<VmService> _vmServiceConnectUri(
  String wsUri, {
  Log log,
  CompressionOptions compression = CompressionOptions.compressionOff,
}) async {
  WebSocket socket = await WebSocket.connect(wsUri, compression: compression);
  StreamController<String> controller = new StreamController();
  socket.listen((dynamic data) => controller.add(data));
  return VmService(
      controller.stream, (String message) => socket.add(message),
      log: log, disposeHandler: () => socket.close());
}

/// Collects coverage for all isolates in the running VM.
///
/// Collects a hit-map containing merged coverage for all isolates in the Dart
/// VM associated with the specified [serviceUri]. Returns a map suitable for
/// input to the coverage formatters that ship with this package.
///
/// [serviceUri] must specify the http/https URI of the service port of a
/// running Dart VM and must not be null.
///
/// If [resume] is true, all isolates will be resumed once coverage collection
/// is complate.
///
/// If [waitPaused] is true, collection will not begin until all isolates are
/// in the paused state.
///
/// [compression] allows specificying the [CompressionOptions] for the
/// websocket used to connect to the vm service. Defaults to
/// [CompressionOptions.compressionOff].
Future<Map<String, dynamic>> collect(
    Uri serviceUri, bool resume, bool waitPaused,
    {Duration timeout,
    CompressionOptions compression = CompressionOptions.compressionOff}) async {
  if (serviceUri == null) throw ArgumentError('serviceUri must not be null');

  // Create websocket URI. Handle any trailing slashes.
  var pathSegments = serviceUri.pathSegments.where((c) => c.isNotEmpty).toList()
    ..add('ws');
  var uri = serviceUri.replace(scheme: 'ws', pathSegments: pathSegments);

  VmService vmService;
  await retry(() async {
    try {
      vmService =
          await _vmServiceConnectUri(uri.toString(), compression: compression);
      await vmService.getVM().timeout(_retryInterval);
    } on TimeoutException {
      vmService.dispose();
      rethrow;
    }
  }, _retryInterval, timeout: timeout);
  try {
    if (waitPaused) {
      await _waitIsolatesPaused(vmService, timeout: timeout);
    }

    return await _getAllCoverage(vmService);
  } finally {
    if (resume) {
      await _resumeIsolates(vmService);
    }
    vmService.dispose();
  }
}

Future<Map<String, dynamic>> _getAllCoverage(VmService vmService) async {
  final VM vm = await vmService.getVM();
  var allCoverage = <Map<String, dynamic>>[];

  for (var isolateRef in vm.isolates) {
    final SourceReport report =
        await vmService.getSourceReport(isolateRef.id, ['Coverage'], forceCompile: true);
    var coverage = await _getCoverageJson(vmService, report, isolateRef);
    allCoverage.addAll(coverage);
  }
  return <String, dynamic>{'type': 'CodeCoverage', 'coverage': allCoverage};
}

Future _resumeIsolates(VmService vmService) async {
  final VM vm = await vmService.getVM();
  for (var isolateRef in vm.isolates) {
    final Isolate isolate = await vmService.getIsolate(isolateRef.id);
    if (_isIsolatePaused(isolate)) {
      await vmService.resume(isolate.id);
    }
  }
}

bool _isIsolatePaused(Isolate isolate) {
  return isolate.pauseEvent.kind != EventKind.kNone &&
      isolate.pauseEvent.kind != EventKind.kResume;
}

Future _waitIsolatesPaused(VmService vmService, {Duration timeout}) async {
  Future allPaused() async {
    final VM vm = await vmService.getVM();
    for (var isolateRef in vm.isolates) {
      final Isolate isolate = await vmService.getIsolate(isolateRef.id);
      if (!_isIsolatePaused(isolate)) {
        throw Exception('Unpaused isolates remaining.');
      }
    }
  }

  return retry(allPaused, _retryInterval, timeout: timeout);
}

/// Returns a JSON coverage list backward-compatible with pre-1.16.0 SDKs.
Future<List<Map<String, dynamic>>> _getCoverageJson(
    VmService service, SourceReport report, IsolateRef isolateRef) async {
  final Set<ScriptRef> scriptRefs = report.ranges
      .map((SourceReportRange range) => report.scripts[range.scriptIndex])
      .toSet();
  var scripts = <ScriptRef, Script>{};
  for (var ref in scriptRefs) {
    scripts[ref] = await service.getObject(isolateRef.id, ref.id);
  }

  // script uri -> { line -> hit count }
  var hitMaps = <Uri, Map<int, int>>{};
  for (SourceReportRange range in report.ranges) {
    final ScriptRef scriptRef = report.scripts[range.scriptIndex];
    final Script script = scripts[scriptRef];
    final Uri uri = Uri.parse(script.uri);
    // Not returned in scripts section of source report.
    if (uri.scheme == 'evaluate') {
      continue;
    }

    hitMaps.putIfAbsent(uri, () => <int, int>{});
    var hitMap = hitMaps[uri];
    for (int hit in range.coverage.hits ?? []) {
      var line = script.tokenPosTable[hit][0] + 1;
      hitMap[line] = hitMap.containsKey(line) ? hitMap[line] + 1 : 1;
    }
    for (int miss in range.coverage.misses ?? []) {
      var line = script.tokenPosTable[miss][0] + 1;
      hitMap.putIfAbsent(line, () => 0);
    }
  }

  // Output JSON
  var coverage = <Map<String, dynamic>>[];
  hitMaps.forEach((uri, hitMap) {
    coverage.add(_toScriptCoverageJson(uri, hitMap));
  });
  return coverage;
}

/// Returns a JSON hit map backward-compatible with pre-1.16.0 SDKs.
Map<String, dynamic> _toScriptCoverageJson(
    Uri scriptUri, Map<int, int> hitMap) {
  var json = <String, dynamic>{};
  var hits = <int>[];
  hitMap.forEach((line, hitCount) {
    hits.add(line);
    hits.add(hitCount);
  });
  json['source'] = '$scriptUri';
  json['script'] = {
    'type': '@Script',
    'fixedId': true,
    'id': 'libraries/1/scripts/${Uri.encodeComponent(scriptUri.toString())}',
    'uri': '$scriptUri',
    '_kind': 'library',
  };
  json['hits'] = hits;
  return json;
}
