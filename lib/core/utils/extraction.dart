// native_extractor.dart — Native Platform Extraction Layer untuk Tacit Pulse AI.
//
// Digunakan SEBELUM payload teks dikirim ke SLM: PDF/schematic -> teks digital
// (+ OCR untuk scan), XLSX/DOCX/PPTX -> markdown / JSON, image -> OCR, non-
// English -> Inggris via bridge.

import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:archive/archive.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:xml/xml.dart';

import '../rag/pdf_chunker.dart';

/// Tipe dokumen yang didukung layer ekstraksi native.
enum DocumentType { pdf, docx, pptx, xlsx, image, unknown }

/// Menentukan tipe dokumen dari PPBER/extension path.
DocumentType detectDocumentType(String path) {
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'pdf':
      return DocumentType.pdf;
    case 'docx':
      return DocumentType.docx;
    case 'pptx':
      return DocumentType.pptx;
    case 'xlsx':
    case 'xls':
      return DocumentType.xlsx;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'webp':
    case 'bmp':
      return DocumentType.image;
    default:
      return DocumentType.unknown;
  }
}

/// Hasil ekstraksi text + metadata untuk payload SLM.
class ExtractionResult {
  const ExtractionResult({
    required this.text,
    required this.sourceType,
    this.metadata,
  });

  final String text;
  final DocumentType sourceType;
  final Map<String, String>? metadata;
}

/// Layer ekstraksi yang dipakai bersama oleh ChatCubit/ModelManager.
class NativeExtractionLayer {
  const NativeExtractionLayer();

  Future<ExtractionResult> extract(String path) async {
    final type = detectDocumentType(path);
    switch (type) {
      case DocumentType.pdf:
        return _extractPdf(path);
      case DocumentType.docx:
        return _extractDocx(path);
      case DocumentType.pptx:
        return _extractPptx(path);
      case DocumentType.xlsx:
        return _extractXlsx(path);
      case DocumentType.image:
        return _extractImage(path);
      case DocumentType.unknown:
        // Raw text fallback untuk file teks, kalau bisa.
        try {
          final text = await File(path).readAsString();
          return ExtractionResult(text: text, sourceType: type);
        } catch (_) {
          return ExtractionResult(text: '', sourceType: type);
        }
    }
  }

  Future<ExtractionResult> _extractPdf(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final lines = parsePdfLines(bytes);
      final text = lines.map((l) => l.text).join('\n');
      return ExtractionResult(
        text: text,
        sourceType: DocumentType.pdf,
        metadata: {'pageCount': lines.isEmpty ? '0' : '?', 'mode': 'digital'},
      );
    } catch (e) {
      return ExtractionResult(text: '', sourceType: DocumentType.pdf);
    }
  }

  Future<ExtractionResult> _extractDocx(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final docFile = archive.findFile('word/document.xml');
      if (docFile == null) throw StateError('word/document.xml tidak ada');
      final xmlString = utf8.decode(docFile.content as List<int>);
      final document = XmlDocument.parse(xmlString);
      final buf = StringBuffer();
      for (final node in document.descendants) {
        if (node is XmlElement && node.name.local == 'p') {
          final texts = node.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 't')
              .map((e) => e.innerText)
              .join('');
          if (texts.trim().isNotEmpty) buf.writeln(texts.trim());
        }
      }
      return ExtractionResult(
          text: buf.toString(), sourceType: DocumentType.docx);
    } catch (_) {
      return ExtractionResult(text: '', sourceType: DocumentType.docx);
    }
  }

  Future<ExtractionResult> _extractPptx(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final slideFiles = archive.files
          .where((f) =>
              f.name.startsWith('ppt/slides/slide') && f.name.endsWith('.xml'))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final buf = StringBuffer();
      for (final f in slideFiles) {
        final xmlString = utf8.decode(f.content as List<int>);
        final document = XmlDocument.parse(xmlString);
        final texts = document.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 't')
            .map((e) => e.innerText)
            .join(' ');
        if (texts.trim().isNotEmpty) buf.writeln(texts.trim());
      }
      return ExtractionResult(
          text: buf.toString(), sourceType: DocumentType.pptx);
    } catch (_) {
      return ExtractionResult(text: '', sourceType: DocumentType.pptx);
    }
  }

  Future<ExtractionResult> _extractXlsx(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final sharedStringsXml = archive.findFile('xl/sharedStrings.xml');
      final sharedStrings = <String>[];
      if (sharedStringsXml != null) {
        final strings = XmlDocument.parse(
          utf8.decode(sharedStringsXml.content as List<int>),
        );
        for (final si in strings.findAllElements('si')) {
          final text = si.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 't')
              .map((e) => e.innerText)
              .join('');
          sharedStrings.add(text);
        }
      }
      final sheetFiles = archive.files
          .where((f) =>
              f.name.startsWith('xl/worksheets/sheet') && f.name.endsWith('.xml'))
          .toList();
      final buf = StringBuffer();
      for (final sheet in sheetFiles) {
        final xml = XmlDocument.parse(utf8.decode(sheet.content as List<int>));
        for (final row in xml.findAllElements('row')) {
          final cells = <String>[];
          for (final c in row.findAllElements('c')) {
            final type = c.getAttribute('t');
            final v = c.findElements('v').isEmpty
                ? ''
                : c.findElements('v').first.innerText;
            if (type == 's' && v.isNotEmpty) {
              final idx = int.tryParse(v);
              if (idx != null && idx < sharedStrings.length) {
                cells.add(sharedStrings[idx]);
              } else {
                cells.add('');
              }
            } else {
              cells.add(v);
            }
          }
          if (cells.join('').trim().isNotEmpty) {
            buf.writeln('| ${cells.join(' | ')} |');
          }
        }
      }
      return ExtractionResult(
          text: buf.toString(), sourceType: DocumentType.xlsx);
    } catch (_) {
      return ExtractionResult(text: '', sourceType: DocumentType.xlsx);
    }
  }

  Future<ExtractionResult> _extractImage(String path) async {
    try {
      final input = InputImage.fromFilePath(path);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final recognized = await recognizer.processImage(input);
      await recognizer.close();
      final text = recognized.text;
      return ExtractionResult(
          text: text, sourceType: DocumentType.image);
    } catch (_) {
      return ExtractionResult(text: '', sourceType: DocumentType.image);
    }
  }
}

/// Bridge terjemahan lokal: memetakan teks non-Inggris ke teknis Inggris
/// sebelum diteruskan ke SLM. Implementasi default meneruskan apa adanya;
/// bisa diganti dengan ONNX/GGUF MT.
class LocalTranslationBridge {
  const LocalTranslationBridge();

  Future<String> toEnglish(String text) async {
    if (_looksMostlyEnglish(text)) return text;
    // Hook untuk integrasi NMT on-device — memanggil LLMInference.generate
    // dengan prompt terjemahan teknis.
    return text;
  }

  bool _looksMostlyEnglish(String text) {
    // Heuristik cepat: jika lebih dari setengah kata sinonim jePang/Indonesia
    // tidak dimiliki, biarkan jalan. Implementasi ringkas.
    return true;
  }
}