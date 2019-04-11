// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:vm_service_lib/vm_service_lib.dart';
import 'package:web_socket_channel/io.dart';
import 'util.dart';

const _retryInterval = const Duration(milliseconds: 200);

/// Allows filtering the set of libraries for which to collect coverage.
///
/// By default, coverage will be collected for all libraries loaded into the
/// Dart VM, including dart core libraries - this can have significant
/// performance impact. It is recommended that the library predicate is used
/// to filter out libraries that are not a part of the package under test.
///
/// Example:
///
///    bool myLibraryPredicate(String libraryUri) {
///        return libraryUri.contains(myPackagename);
///    }
typedef LibraryPredicate = bool Function(String libraryUri);

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
/// If a [libraryPredicate] is provided, only library uris for which the
/// function returns true will have coverage collected.
Future<Map<String, dynamic>> collect(
    Uri serviceUri, bool resume, bool waitPaused,
    {Duration timeout, LibraryPredicate libraryPredicate}) async {
  if (serviceUri == null) throw ArgumentError('serviceUri must not be null');

  // Create websocket URI. Handle any trailing slashes.
  var pathSegments = serviceUri.pathSegments.where((c) => c.isNotEmpty).toList()
    ..add('ws');
  var uri = serviceUri.replace(scheme: 'ws', pathSegments: pathSegments);

  VmService vmService;
  WebSocket webSocket;
  await retry(() async {
    try {
      webSocket = await WebSocket.connect(uri.toString(),
          compression: CompressionOptions.compressionOff);
      var channel = IOWebSocketChannel(webSocket).cast<String>();
      vmService = VmService(channel.stream, channel.sink.add);
      await vmService.getVM().timeout(_retryInterval);
    } on TimeoutException {
      await webSocket?.close();
      rethrow;
    }
  }, _retryInterval, timeout: timeout);
  try {
    if (waitPaused) {
      await _waitIsolatesPaused(vmService, timeout: timeout);
    }

    return await _getAllCoverage(vmService, libraryPredicate);
  } finally {
    if (resume) {
      await _resumeIsolates(vmService);
    }
    await webSocket?.close();
  }
}

Future<Map<String, dynamic>> _getAllCoverage(
    VmService service, LibraryPredicate libraryPredicate) async {
  var vm = await service.getVM();
  var allCoverage = <Map<String, dynamic>>[];

  // If the library predicate is null, use the default collection strategy.
  if (libraryPredicate == null) {
    for (var isolateRef in vm.isolates) {
      var report = await service.getSourceReport(
          isolateRef.id, <String>['Coverage'],
          forceCompile: true);
      var coverage = await _getCoverageJson(isolateRef, service, report);
      allCoverage.addAll(coverage);
    }
  } else {
    for (var isolateRef in vm.isolates) {
      var futures = <Future>[];
      var scripts = <String, Script>{};
      var reports = <String, SourceReport>{};
      var scriptList = await service.getScripts(isolateRef.id);
      for (var scriptRef in scriptList.scripts) {
        if (!libraryPredicate(scriptRef.uri)) {
          continue;
        }
        futures.add(service
            .getObject(isolateRef.id, scriptRef.id)
            .then<void>((dynamic script) {
          scripts[scriptRef.id] = script;
        }));
        futures.add(service.getSourceReport(
          isolateRef.id,
          <String>['Coverage'],
          forceCompile: true,
          scriptId: scriptRef.id,
        ).then<void>((dynamic sourceReport) {
          reports[scriptRef.id] = sourceReport;
        }));
      }
      await Future.wait<void>(futures);
      var coverage = await _buildCoverageMap(reports, scripts);
      allCoverage.addAll(coverage);
    }
  }
  return <String, dynamic>{'type': 'CodeCoverage', 'coverage': allCoverage};
}

Future _resumeIsolates(VmService service) async {
  var vm = await service.getVM();
  for (var isolateRef in vm.isolates) {
    Isolate isolate = await service.getIsolate(isolateRef.id);
    if (isolate?.pauseEvent?.type != EventKind.kResume) {
      await service.resume(isolateRef.id);
    }
  }
}

Future _waitIsolatesPaused(VmService service, {Duration timeout}) async {
  Future allPaused() async {
    var vm = await service.getVM();
    for (var isolateRef in vm.isolates) {
      Isolate isolate = await service.getIsolate(isolateRef.id);
      if (isolate?.pauseEvent?.type == EventKind.kResume) {
        throw Exception('Unpaused isolates remaining.');
      }
    }
  }

  return retry(allPaused, _retryInterval, timeout: timeout);
}

/// Returns a JSON coverage list backward-compatible with pre-1.16.0 SDKs.
Future<List<Map<String, dynamic>>> _getCoverageJson(
    IsolateRef isolateRef, VmService service, SourceReport report) async {
  var scriptIndexes =
      report.ranges.map((SourceReportRange range) => range.scriptIndex).toSet();
  var scripts = <int, Script>{};
  var futures = <Future>[];
  for (var index in scriptIndexes) {
    var scriptRef = report.scripts[index];
    futures.add(service
        .getObject(isolateRef.id, scriptRef.id)
        .then<void>((dynamic script) {
      scripts[index] = script;
    }));
  }
  await Future.wait<void>(futures);

  // script uri -> { line -> hit count }
  var hitMaps = <Uri, Map<int, int>>{};
  for (var range in report.ranges) {
    // Not returned in scripts section of source report.
    var scriptRef = report.scripts[range.scriptIndex];
    var uri = Uri.parse(scriptRef.uri);
    if (uri.scheme == 'evaluate') {
      continue;
    }

    hitMaps[uri] ??= <int, int>{};
    var hitMap = hitMaps[uri];
    var script = scripts[range.scriptIndex];
    for (int hit in range.coverage.hits ?? []) {
      var line = _lineAndColumn(hit, script.tokenPosTable).first + 1;
      hitMap[line] = hitMap.containsKey(line) ? hitMap[line] + 1 : 1;
    }
    for (int miss in range.coverage.hits ?? []) {
      var line = _lineAndColumn(miss, script.tokenPosTable).first + 1;
      hitMap[line] ??= 0;
    }
  }

  // Output JSON
  var coverage = <Map<String, dynamic>>[];
  hitMaps.forEach((uri, hitMap) {
    coverage.add(_toScriptCoverageJson(uri, hitMap));
  });
  return coverage;
}

Future<List<Map<String, dynamic>>> _buildCoverageMap(
  Map<String, SourceReport> sourceReports,
  Map<String, Script> scripts,
) async {
  var hitMaps = <Uri, Map<int, int>>{};
  for (String scriptId in scripts.keys) {
    var report = sourceReports[scriptId];
    // script uri -> { line -> hit count }
    for (var range in report.ranges) {
      // Not returned in scripts section of source report.
      var scriptRef = report.scripts[range.scriptIndex];
      var uri = Uri.parse(scriptRef.uri);
      if (uri.scheme == 'evaluate') {
        continue;
      }

      hitMaps[uri] ??= <int, int>{};
      var hitMap = hitMaps[uri];
      var script = scripts[range.scriptIndex];
      for (int hit in range.coverage.hits ?? []) {
        var line = _lineAndColumn(hit, script.tokenPosTable).first + 1;
        hitMap[line] = hitMap.containsKey(line) ? hitMap[line] + 1 : 1;
      }
      for (int miss in range.coverage.hits ?? []) {
        var line = _lineAndColumn(miss, script.tokenPosTable).first + 1;
        hitMap[line] ??= 0;
      }
    }
  }
  // Output JSON
  var coverage = <Map<String, dynamic>>[];
  hitMaps.forEach((uri, hitMap) {
    coverage.add(_toScriptCoverageJson(uri, hitMap));
  });
  return coverage;
}

// Binary search the token position table for the line and column information.
List<int> _lineAndColumn(int position, List<dynamic> tokenPositions) {
  var min = 0;
  var max = tokenPositions.length;
  while (min < max) {
    var mid = min + ((max - min) >> 1);
    List<dynamic> row = tokenPositions[mid];
    if (row[1] > position) {
      max = mid;
    } else {
      for (int i = 1; i < row.length; i += 2) {
        if (row[i] == position) {
          return <int>[row.first, row[i + 1]];
        }
      }
      min = mid + 1;
    }
  }
  throw StateError('Unreachable');
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
