import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

abstract interface class PoseExportSharer {
  Future<void> shareJsonFile({
    required String fileName,
    required String contents,
    Rect? sharePositionOrigin,
  });
}

class SharePlusPoseExportSharer implements PoseExportSharer {
  const SharePlusPoseExportSharer();

  @override
  Future<void> shareJsonFile({
    required String fileName,
    required String contents,
    Rect? sharePositionOrigin,
  }) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(contents, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile(file.path, mimeType: 'application/json', name: fileName),
        ],
        subject: fileName,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}

String encodePoseMotionDocument(Map<String, Object?> document) {
  return const JsonEncoder.withIndent('  ').convert(document);
}
