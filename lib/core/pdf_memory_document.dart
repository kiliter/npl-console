import 'dart:typed_data';
import 'package:pdfrx/pdfrx.dart';
import 'pdf_diagnostics.dart';

/// 完整内存数据不再进入超过 1MB 后的 Windows 异步文件读取回调。
PdfDocumentRefCustom memoryPdfReference(Uint8List bytes, String sourceName) =>
    PdfDocumentRefCustom(
      fileSize: bytes.length,
      maxSizeToCacheOnMemory: bytes.length,
      sourceName: sourceName,
      key: PdfDocumentRefKey(sourceName, [bytes]),
      useProgressiveLoading: false,
      read: (buffer, position, size) {
        if (position < 0 || position > bytes.length) return -1;
        final count = size.clamp(0, bytes.length - position);
        buffer.setRange(0, count, bytes, position);
        return count;
      },
    );

Future<PdfDocument> openMemoryPdf(Uint8List bytes, String sourceName) =>
    PdfDiagnostics.trace(
      'PDF内存打开',
      () => memoryPdfReference(bytes, sourceName).loadDocument((_, [total]) {}),
      data: {'文档': sourceName, '字节数': bytes.length},
    );
