import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/element/element.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/element/element.dart';
import 'package:path/path.dart';
import 'package:source_span/source_span.dart';

import '../../config_builder/config_builder.dart';
import '../../config_builder/models/analysis_options.dart';
import '../../reporters/models/reporter.dart';
import '../../utils/analyzer_utils.dart';
import '../../utils/file_utils.dart';
import 'models/file_elements_usage.dart';
import 'models/unused_code_file_report.dart';
import 'models/unused_code_issue.dart';
import 'public_code_visitor.dart';
import 'reporters/reporter_factory.dart';
import 'unused_code_analysis_config.dart';
import 'unused_code_config.dart';
import 'used_code_visitor.dart';

/// The analyzer responsible for collecting unused code reports.
class UnusedCodeAnalyzer {
  const UnusedCodeAnalyzer();

  /// Returns a reporter for the given [name]. Use the reporter
  /// to convert analysis reports to console, JSON or other supported format.
  Reporter<UnusedCodeFileReport, void, void>? getReporter({
    required String name,
    required IOSink output,
  }) =>
      reporter(
        name: name,
        output: output,
      );

  /// Returns a list of unused code reports
  /// for analyzing all files in the given [folders].
  /// The analysis is configured with the [config].
  Future<Iterable<UnusedCodeFileReport>> runCliAnalysis(
    Iterable<String> folders,
    String rootFolder,
    UnusedCodeConfig config, {
    String? sdkPath,
  }) async {
    final collection =
        createAnalysisContextCollection(folders, rootFolder, sdkPath);

    final codeUsages = FileElementsUsage();
    final publicCode = <String, Set<Element>>{};

    for (final context in collection.contexts) {
      final unusedCodeAnalysisConfig =
          await _getAnalysisConfig(context, rootFolder, config);

      final filePaths =
          _getFilePaths(folders, context, rootFolder, unusedCodeAnalysisConfig);

      final analyzedFiles =
          filePaths.intersection(context.contextRoot.analyzedFiles().toSet());
      await _analyseFiles(
        analyzedFiles,
        context.currentSession.getResolvedUnit,
        codeUsages,
        publicCode,
      );

      final notAnalyzedFiles = filePaths.difference(analyzedFiles);
      await _analyseFiles(
        notAnalyzedFiles,
        (filePath) => resolveFile2(path: filePath),
        codeUsages,
        publicCode,
        shouldAnalyse: (filePath) => unusedCodeAnalysisConfig
            .analyzerExcludedPatterns
            .any((pattern) => pattern.matches(filePath)),
      );
    }

    codeUsages.exports.forEach(publicCode.remove);

    return _getReports(codeUsages, publicCode, rootFolder);
  }

  Future<UnusedCodeAnalysisConfig> _getAnalysisConfig(
    AnalysisContext context,
    String rootFolder,
    UnusedCodeConfig config,
  ) async {
    final analysisOptions = await analysisOptionsFromContext(context) ??
        await analysisOptionsFromFilePath(rootFolder);

    final contextConfig =
        ConfigBuilder.getUnusedCodeConfigFromOption(analysisOptions)
            .merge(config);

    return ConfigBuilder.getUnusedCodeConfig(contextConfig, rootFolder);
  }

  Set<String> _getFilePaths(
    Iterable<String> folders,
    AnalysisContext context,
    String rootFolder,
    UnusedCodeAnalysisConfig unusedCodeAnalysisConfig,
  ) {
    final contextFolders = folders
        .where((path) => normalize(join(rootFolder, path))
            .startsWith(context.contextRoot.root.path))
        .toList();

    return extractDartFilesFromFolders(
      contextFolders,
      rootFolder,
      unusedCodeAnalysisConfig.globalExcludes,
    );
  }

  FileElementsUsage? _analyzeFileCodeUsages(SomeResolvedUnitResult unit) {
    if (unit is ResolvedUnitResult) {
      final visitor = UsedCodeVisitor();
      unit.unit.visitChildren(visitor);

      return visitor.fileElementsUsage;
    }

    return null;
  }

  Set<Element> _analyzeFilePublicCode(SomeResolvedUnitResult unit) {
    if (unit is ResolvedUnitResult) {
      final visitor = PublicCodeVisitor();
      unit.unit.visitChildren(visitor);

      return visitor.topLevelElements;
    }

    return {};
  }

  Future<void> _analyseFiles(
    Set<String> files,
    Future<SomeResolvedUnitResult> Function(String) unitExtractor,
    FileElementsUsage codeUsages,
    Map<String, Set<Element>> publicCode, {
    bool Function(String)? shouldAnalyse,
  }) async {
    for (final filePath in files) {
      if (shouldAnalyse == null || shouldAnalyse(filePath)) {
        final unit = await unitExtractor(filePath);

        final codeUsage = _analyzeFileCodeUsages(unit);
        if (codeUsage != null) {
          codeUsages.merge(codeUsage);
        }

        publicCode[filePath] = _analyzeFilePublicCode(unit);
      }
    }
  }

  Iterable<UnusedCodeFileReport> _getReports(
    FileElementsUsage codeUsages,
    Map<String, Set<Element>> publicCodeElements,
    String rootFolder,
  ) {
    final unusedCodeReports = <UnusedCodeFileReport>[];

    publicCodeElements.forEach((path, elements) {
      final issues = <UnusedCodeIssue>[];

      for (final element in elements) {
        if (!codeUsages.elements
                .any((usedElement) => _isUsed(usedElement, element)) &&
            !codeUsages.usedExtensions
                .any((usedElement) => _isUsed(usedElement, element))) {
          final unit = element.thisOrAncestorOfType<CompilationUnitElement>();
          if (unit != null) {
            issues.add(_createUnusedCodeIssue(element as ElementImpl, unit));
          }
        }
      }

      final relativePath = relative(path, from: rootFolder);

      if (issues.isNotEmpty) {
        unusedCodeReports.add(UnusedCodeFileReport(
          path: path,
          relativePath: relativePath,
          issues: issues,
        ));
      }
    });

    return unusedCodeReports;
  }

  bool _isUsed(Element usedElement, Element element) =>
      element == usedElement ||
      element is PropertyInducingElement && element.getter == usedElement;

  UnusedCodeIssue _createUnusedCodeIssue(
    ElementImpl element,
    CompilationUnitElement unit,
  ) {
    final offset = element.codeOffset!;

    final lineInfo = unit.lineInfo!;
    final offsetLocation = lineInfo.getLocation(offset);

    final sourceUrl = element.source!.uri;

    return UnusedCodeIssue(
      declarationName: element.displayName,
      declarationType: element.kind.displayName,
      location: SourceLocation(
        offset,
        sourceUrl: sourceUrl,
        line: offsetLocation.lineNumber,
        column: offsetLocation.columnNumber,
      ),
    );
  }
}