// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:ui/ui.dart' as ui;

import '../../engine.dart' show registerHotRestartListener;
import '../dom_renderer.dart';
import '../util.dart';
import '../web_experiments.dart';
import '../window.dart';
import 'line_break_properties.dart';
import 'line_breaker.dart';
import 'paragraph.dart';
import 'ruler.dart';

// TODO(yjbanov): this is a hack we use to compute ideographic baseline; this
//                number is the ratio ideographic/alphabetic for font Ahem,
//                which matches the Flutter number. It may be completely wrong
//                for any other font. We'll need to eventually fix this. That
//                said Flutter doesn't seem to use ideographic baseline for
//                anything as of this writing.
const double baselineRatioHack = 1.1662499904632568;

/// Signature of a function that takes a character and returns true or false.
typedef CharPredicate = bool Function(int char);

bool _newlinePredicate(int char) {
  final LineCharProperty prop = lineLookup.findForChar(char);
  return prop == LineCharProperty.BK ||
      prop == LineCharProperty.LF ||
      prop == LineCharProperty.CR;
}

/// Hosts ruler DOM elements in a hidden container under a `root` [html.Node].
///
/// The `root` [html.Node] is optional. Defaults to [domRenderer.glassPaneShadow].
class RulerHost {
  RulerHost({html.Node? root}) {
    _rulerHost.style
      ..position = 'fixed'
      ..visibility = 'hidden'
      ..overflow = 'hidden'
      ..top = '0'
      ..left = '0'
      ..width = '0'
      ..height = '0';

    (root ?? domRenderer.glassPaneShadow!.node).append(_rulerHost);
    registerHotRestartListener(dispose);
  }

  /// Hosts a cache of rulers that measure text.
  ///
  /// This element exists purely for organizational purposes. Otherwise the
  /// rulers would be attached to the `<body>` element polluting the element
  /// tree and making it hard to navigate. It does not serve any functional
  /// purpose.
  final html.Element _rulerHost = html.Element.tag('flt-ruler-host');

  /// Releases the resources used by this [RulerHost].
  ///
  /// After this is called, this object is no longer usable.
  void dispose() {
    _rulerHost.remove();
  }

  /// Adds an element used for measuring text as a child of [_rulerHost].
  void addElement(html.HtmlElement element) {
    _rulerHost.append(element);
  }
}

/// Manages [ParagraphRuler] instances and caches them per unique
/// [ParagraphGeometricStyle].
///
/// All instances of [ParagraphRuler] should be created through this class.
///
/// An optional `root` [html.Node] can be passed, under which the DOM required
/// to perform measurements will be hosted.
class RulerManager extends RulerHost {
  RulerManager({
    required this.rulerCacheCapacity,
    html.Node? root,
  }) : super(root: root);

  final int rulerCacheCapacity;

  /// The cache of rulers used to measure text.
  ///
  /// Each ruler is keyed by paragraph style. This allows us to set up the
  /// ruler's DOM structure once during the very first measurement of a given
  /// paragraph style. Subsequent measurements could reuse the same ruler and
  /// only swap the text contents. This minimizes the amount of work a browser
  /// needs to do when measure many pieces of text with the same style.
  ///
  /// What makes this cache effective is the fact that a typical application
  /// only uses a limited number of text styles. Using too many text styles on
  /// the same screen is considered bad for user experience.
  Map<ParagraphGeometricStyle, ParagraphRuler> get rulers => _rulers;
  Map<ParagraphGeometricStyle, ParagraphRuler> _rulers =
      <ParagraphGeometricStyle, ParagraphRuler>{};

  bool _rulerCacheCleanupScheduled = false;

  void _scheduleRulerCacheCleanup() {
    if (!_rulerCacheCleanupScheduled) {
      _rulerCacheCleanupScheduled = true;
      scheduleMicrotask(() {
        _rulerCacheCleanupScheduled = false;
        cleanUpRulerCache();
      });
    }
  }

  // Evicts all rulers from the cache.
  void _evictAllRulers() {
    _rulers.forEach((ParagraphGeometricStyle style, ParagraphRuler ruler) {
      ruler.dispose();
    });
    _rulers = <ParagraphGeometricStyle, ParagraphRuler>{};
  }

  /// If [window._isPhysicalSizeActuallyEmpty], evicts all rulers from the cache.
  /// If ruler cache size exceeds [rulerCacheCapacity], evicts those rulers that
  /// were used the least.
  ///
  /// Resets hit counts back to zero.
  @visibleForTesting
  void cleanUpRulerCache() {
    // Measurements performed (and cached) inside a hidden iframe (with
    // display:none) are wrong.
    // Evict all rulers, so text gets re-measured when the iframe becomes
    // visible.
    // see: https://github.com/flutter/flutter/issues/36341
    if (window.physicalSize.isEmpty) {
      _evictAllRulers();
      return;
    }
    if (_rulers.length > rulerCacheCapacity) {
      final List<ParagraphRuler> sortedByUsage = _rulers.values.toList();
      sortedByUsage.sort((ParagraphRuler a, ParagraphRuler b) {
        return b.hitCount - a.hitCount;
      });
      _rulers = <ParagraphGeometricStyle, ParagraphRuler>{};
      for (int i = 0; i < sortedByUsage.length; i++) {
        final ParagraphRuler ruler = sortedByUsage[i];
        ruler.resetHitCount();
        if (i < rulerCacheCapacity) {
          // Retain this ruler.
          _rulers[ruler.style] = ruler;
        } else {
          // This ruler did not have enough usage this frame to be retained.
          ruler.dispose();
        }
      }
    }
  }

  /// Performs a cache lookup to find an existing [ParagraphRuler] for the given
  /// [style] and if it can't find one in the cache, it would create one.
  ///
  /// The returned ruler is marked as hit so there's no need to do that
  /// elsewhere.
  @visibleForTesting
  ParagraphRuler findOrCreateRuler(ParagraphGeometricStyle style) {
    ParagraphRuler? ruler = _rulers[style];
    if (ruler == null) {
      if (assertionsEnabled) {
        domRenderer.debugRulerCacheMiss();
      }
      ruler = _rulers[style] = ParagraphRuler(style, this);
      _scheduleRulerCacheCleanup();
    } else {
      if (assertionsEnabled) {
        domRenderer.debugRulerCacheHit();
      }
    }
    ruler.hit();
    return ruler;
  }
}

/// Provides various text measurement APIs using either a dom-based approach
/// in [DomTextMeasurementService], or a canvas-based approach in
/// [CanvasTextMeasurementService].
abstract class TextMeasurementService {
  /// Whether this service uses a canvas to make the text measurements.
  ///
  /// If [isCanvas] is false, it indicates that this service uses DOM elements
  /// to make the text measurements.
  bool get isCanvas;

  /// Initializes the text measurement service with a specific
  /// [rulerCacheCapacity] that gets passed to the [RulerManager].
  ///
  /// An optional `root` [html.Node] can be passed, under which the DOM required
  /// to perform measurements will be hosted. Defaults to [domRenderer.glassPaneShadow].
  static void initialize({required int rulerCacheCapacity, html.Node? root}) {
    rulerManager?.dispose();
    rulerManager = null;
    rulerManager = RulerManager(
      rulerCacheCapacity: rulerCacheCapacity,
      root: root,
    );
  }

  @visibleForTesting
  static RulerManager? rulerManager;

  /// The DOM-based text measurement service.
  @visibleForTesting
  static TextMeasurementService get domInstance =>
      DomTextMeasurementService.instance;

  /// The canvas-based text measurement service.
  @visibleForTesting
  static TextMeasurementService get canvasInstance =>
      CanvasTextMeasurementService.instance;

  /// Gets the appropriate [TextMeasurementService] instance for the given
  /// [paragraph].
  static TextMeasurementService forParagraph(ui.Paragraph paragraph) {
    // TODO(flutter_web): https://github.com/flutter/flutter/issues/33523
    // When the canvas-based implementation is complete and passes all the
    // tests, get rid of [_experimentalEnableCanvasImplementation].
    // We need to check [window.physicalSize.isEmpty] because some canvas
    // commands don't work as expected when they run inside a hidden iframe
    // (with display:none)
    // Skip using canvas measurements until the iframe becomes visible.
    // see: https://github.com/flutter/flutter/issues/36341
    if (!window.physicalSize.isEmpty &&
        WebExperiments.instance!.useCanvasText &&
        _canUseCanvasMeasurement(paragraph as DomParagraph)) {
      return canvasInstance;
    }
    return domInstance;
  }

  /// Clears the cache of paragraph rulers that are used for measuring paragraph
  /// metrics.
  static void clearCache() {
    rulerManager?._evictAllRulers();
  }

  static bool _canUseCanvasMeasurement(DomParagraph paragraph) {
    // Currently, the canvas-based approach only works on plain text that
    // doesn't have any of the following styles:
    // - decoration
    // - word spacing
    final ParagraphGeometricStyle style = paragraph.geometricStyle;
    return paragraph.plainText != null &&
        style.decoration == null &&
        style.wordSpacing == null;
  }

  /// Measures the paragraph and returns a [MeasurementResult] object.
  MeasurementResult? measure(
    DomParagraph paragraph,
    ui.ParagraphConstraints constraints,
  ) {
    assert(rulerManager != null);
    final ParagraphGeometricStyle style = paragraph.geometricStyle;
    final ParagraphRuler ruler =
        TextMeasurementService.rulerManager!.findOrCreateRuler(style);

    if (assertionsEnabled) {
      if (paragraph.plainText == null) {
        domRenderer.debugRichTextLayout();
      } else {
        domRenderer.debugPlainTextLayout();
      }
    }

    MeasurementResult? result = ruler.cacheLookup(paragraph, constraints);
    if (result != null) {
      return result;
    }

    result = _doMeasure(paragraph, constraints, ruler);
    ruler.cacheMeasurement(paragraph, result);
    return result;
  }

  /// Measures the width of a substring of the given [paragraph] with no
  /// constraints.
  double measureSubstringWidth(DomParagraph paragraph, int start, int end);

  /// Returns text position given a paragraph, constraints and offset.
  ui.TextPosition getTextPositionForOffset(DomParagraph paragraph,
      ui.ParagraphConstraints? constraints, ui.Offset offset);

  /// Delegates to a [ParagraphRuler] to measure a list of text boxes that
  /// enclose the given range of text.
  List<ui.TextBox> measureBoxesForRange(
    DomParagraph paragraph,
    ui.ParagraphConstraints constraints, {
    required int start,
    required int end,
    required double alignOffset,
    required ui.TextDirection textDirection,
  }) {
    final ParagraphGeometricStyle style = paragraph.geometricStyle;
    final ParagraphRuler ruler =
        TextMeasurementService.rulerManager!.findOrCreateRuler(style);

    return ruler.measureBoxesForRange(
      paragraph.plainText!,
      constraints,
      start: start,
      end: end,
      alignOffset: alignOffset,
      textDirection: textDirection,
    );
  }

  /// Performs the actual measurement of the following values for the given
  /// paragraph:
  ///
  /// * isSingleLine: whether the paragraph can be rendered in a single line.
  /// * height: constrained measure of the entire paragraph's height.
  /// * lineHeight: the height of a single line of the paragraph.
  /// * alphabeticBaseline: single line measure.
  /// * ideographicBaseline: based on [alphabeticBaseline].
  /// * maxIntrinsicWidth: the width of the paragraph with no line-wrapping.
  /// * minIntrinsicWidth: the min width the paragraph fits in without overflowing.
  ///
  /// [MeasurementResult.width] is set to the same value of [constraints.width].
  ///
  /// It also optionally computes [MeasurementResult.lines] in the given
  /// paragraph. When that's available, it can be used by a canvas to render
  /// the text line.
  MeasurementResult _doMeasure(
    DomParagraph paragraph,
    ui.ParagraphConstraints constraints,
    ParagraphRuler ruler,
  );
}

/// A DOM-based text measurement implementation.
///
/// This implementation is slower than [CanvasTextMeasurementService] but it's
/// needed for some cases that aren't yet supported in the canvas-based
/// implementation such as letter-spacing, word-spacing, etc.
class DomTextMeasurementService extends TextMeasurementService {
  @override
  final bool isCanvas = false;

  /// The text measurement service singleton.
  static DomTextMeasurementService get instance =>
      _instance ??= DomTextMeasurementService();

  static DomTextMeasurementService? _instance;

  @override
  MeasurementResult _doMeasure(
    DomParagraph paragraph,
    ui.ParagraphConstraints constraints,
    ParagraphRuler ruler,
  ) {
    ruler.willMeasure(paragraph);
    final String? plainText = paragraph.plainText;

    ruler.measureAll(constraints);

    MeasurementResult result;
    // When the text has a new line, we should always use multi-line mode.
    final bool hasNewline = plainText?.contains('\n') ?? false;
    if (!hasNewline && ruler.singleLineDimensions.width <= constraints.width) {
      result = _measureSingleLineParagraph(ruler, paragraph, constraints);
    } else {
      // Assert: If text doesn't have new line for infinite constraints we
      // should have called single line measure paragraph instead.
      assert(hasNewline || constraints.width != double.infinity);
      result = _measureMultiLineParagraph(ruler, paragraph, constraints);
    }
    ruler.didMeasure();
    return result;
  }

  @override
  double measureSubstringWidth(DomParagraph paragraph, int start, int end) {
    assert(paragraph.plainText != null);
    final ParagraphGeometricStyle style = paragraph.geometricStyle;
    final ParagraphRuler ruler =
        TextMeasurementService.rulerManager!.findOrCreateRuler(style);

    final String text = paragraph.plainText!.substring(start, end);
    final ui.Paragraph substringParagraph = paragraph.cloneWithText(text);

    ruler.willMeasure(substringParagraph as DomParagraph);
    ruler.measureAsSingleLine();
    final TextDimensions dimensions = ruler.singleLineDimensions;
    ruler.didMeasure();
    return dimensions.width;
  }

  @override
  ui.TextPosition getTextPositionForOffset(DomParagraph paragraph,
      ui.ParagraphConstraints? constraints, ui.Offset offset) {
    assert(
      paragraph.measurementResult!.lines == null,
      'should only be called when the faster lines-based approach is not possible',
    );

    final ParagraphGeometricStyle style = paragraph.geometricStyle;
    final ParagraphRuler ruler =
        TextMeasurementService.rulerManager!.findOrCreateRuler(style);
    ruler.willMeasure(paragraph);
    final int position = ruler.hitTest(constraints!, offset);
    ruler.didMeasure();
    return ui.TextPosition(offset: position);
  }

  /// Called when we have determined that the paragraph fits the [constraints]
  /// without wrapping.
  ///
  /// This means that:
  /// * `width == maxIntrinsicWidth` - we gave it more horizontal space than
  ///   it needs and so the paragraph won't expand beyond `maxIntrinsicWidth`.
  /// * `height` is the height computed by `measureAsSingleLine`; giving the
  ///    paragraph the width constraint won't change its height as we already
  ///    determined that it fits within the constraint without wrapping.
  /// * `alphabeticBaseline` is also final for the same reason as the `height`
  ///   value.
  ///
  /// This method still needs to measure `minIntrinsicWidth`.
  MeasurementResult _measureSingleLineParagraph(
    ParagraphRuler ruler,
    DomParagraph paragraph,
    ui.ParagraphConstraints constraints,
  ) {
    final double width = constraints.width;
    final double minIntrinsicWidth = ruler.minIntrinsicDimensions.width;
    double maxIntrinsicWidth = ruler.singleLineDimensions.width;
    final double alphabeticBaseline = ruler.alphabeticBaseline;
    final double height = ruler.singleLineDimensions.height;

    maxIntrinsicWidth =
        _applySubPixelRoundingHack(minIntrinsicWidth, maxIntrinsicWidth);
    final double ideographicBaseline = alphabeticBaseline * baselineRatioHack;

    final String? text = paragraph.plainText;
    List<EngineLineMetrics>? lines;
    if (text != null) {
      final double lineWidth = maxIntrinsicWidth;
      final double alignOffset = _calculateAlignOffsetForLine(
        paragraph: paragraph,
        lineWidth: lineWidth,
        maxWidth: width,
      );
      lines = <EngineLineMetrics>[
        EngineLineMetrics.withText(
          text,
          startIndex: 0,
          endIndex: text.length,
          endIndexWithoutNewlines:
              _excludeTrailing(text, 0, text.length, _newlinePredicate),
          hardBreak: true,
          width: lineWidth,
          widthWithTrailingSpaces: lineWidth,
          left: alignOffset,
          lineNumber: 0,
        ),
      ];
    }

    return MeasurementResult(
      constraints.width,
      isSingleLine: true,
      width: width,
      height: height,
      naturalHeight: height,
      lineHeight: height,
      minIntrinsicWidth: minIntrinsicWidth,
      maxIntrinsicWidth: maxIntrinsicWidth,
      alphabeticBaseline: alphabeticBaseline,
      ideographicBaseline: ideographicBaseline,
      lines: lines,
      placeholderBoxes: ruler.measurePlaceholderBoxes(),
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
    );
  }

  /// Called when we have determined that the paragraph needs to wrap into
  /// multiple lines to fit the [constraints], i.e. its `maxIntrinsicWidth` is
  /// bigger than the available horizontal space.
  ///
  /// While `maxIntrinsicWidth` is still good from the call to
  /// `measureAsSingleLine`, we need to re-measure with the width constraint
  /// and get new values for width, height and alphabetic baseline. We also need
  /// to measure `minIntrinsicWidth`.
  MeasurementResult _measureMultiLineParagraph(ParagraphRuler ruler,
      DomParagraph paragraph, ui.ParagraphConstraints constraints) {
    // If constraint is infinite, we must use _measureSingleLineParagraph
    final double width = constraints.width;
    final double minIntrinsicWidth = ruler.minIntrinsicDimensions.width;
    double maxIntrinsicWidth = ruler.singleLineDimensions.width;
    final double alphabeticBaseline = ruler.alphabeticBaseline;
    // Natural height is the full height of text ignoring height constraints.
    final double naturalHeight = ruler.constrainedDimensions.height;

    double height;
    double? lineHeight;
    final int? maxLines = paragraph.geometricStyle.maxLines;
    if (maxLines == null) {
      height = naturalHeight;
    } else {
      // Lazily compute [lineHeight] when [maxLines] is not null.
      lineHeight = ruler.lineHeight;
      height = math.min(naturalHeight, maxLines * lineHeight);
    }

    maxIntrinsicWidth =
        _applySubPixelRoundingHack(minIntrinsicWidth, maxIntrinsicWidth);
    assert(minIntrinsicWidth <= maxIntrinsicWidth);
    final double ideographicBaseline = alphabeticBaseline * baselineRatioHack;
    return MeasurementResult(
      constraints.width,
      isSingleLine: false,
      width: width,
      height: height,
      lineHeight: lineHeight,
      naturalHeight: naturalHeight,
      minIntrinsicWidth: minIntrinsicWidth,
      maxIntrinsicWidth: maxIntrinsicWidth,
      alphabeticBaseline: alphabeticBaseline,
      ideographicBaseline: ideographicBaseline,
      lines: null,
      placeholderBoxes: ruler.measurePlaceholderBoxes(),
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
    );
  }

  /// This hack is needed because `offsetWidth` rounds the value to the nearest
  /// whole number. On a very rare occasion the minimum intrinsic width reported
  /// by the browser is slightly bigger than the reported maximum intrinsic
  /// width. If the discrepancy overlaps 0.5 then the rounding happens in
  /// opposite directions.
  ///
  /// For example, if minIntrinsicWidth == 99.5 and maxIntrinsicWidth == 99.48,
  /// then minIntrinsicWidth is rounded up to 100, and maxIntrinsicWidth is
  /// rounded down to 99.
  // TODO(yjbanov): remove the need for this hack.
  static double _applySubPixelRoundingHack(
      double minIntrinsicWidth, double maxIntrinsicWidth) {
    if (minIntrinsicWidth <= maxIntrinsicWidth) {
      return maxIntrinsicWidth;
    }

    if (minIntrinsicWidth - maxIntrinsicWidth < 2.0) {
      return minIntrinsicWidth;
    }

    throw Exception('minIntrinsicWidth ($minIntrinsicWidth) is greater than '
        'maxIntrinsicWidth ($maxIntrinsicWidth).');
  }
}

/// A canvas-based text measurement implementation.
///
/// This is a faster implementation than [DomTextMeasurementService] and
/// provides line breaks information that can be useful for multi-line text.
class CanvasTextMeasurementService extends TextMeasurementService {
  @override
  final bool isCanvas = true;

  /// The text measurement service singleton.
  static CanvasTextMeasurementService get instance =>
      _instance ??= CanvasTextMeasurementService();

  static CanvasTextMeasurementService? _instance;

  final html.CanvasRenderingContext2D _canvasContext =
      html.CanvasElement().context2D;

  @override
  MeasurementResult _doMeasure(
    DomParagraph paragraph,
    ui.ParagraphConstraints constraints,
    ParagraphRuler ruler,
  ) {
    final String text = paragraph.plainText!;
    final ParagraphGeometricStyle style = paragraph.geometricStyle;
    assert(text != null); // ignore: unnecessary_null_comparison

    // TODO(mdebbar): Check if the whole text can fit in a single-line. Then avoid all this ceremony.
    _canvasContext.font = style.cssFontString;
    final LinesCalculator linesCalculator =
        LinesCalculator(_canvasContext, paragraph, constraints.width);
    final MinIntrinsicCalculator minIntrinsicCalculator =
        MinIntrinsicCalculator(_canvasContext, text, style);
    final MaxIntrinsicCalculator maxIntrinsicCalculator =
        MaxIntrinsicCalculator(_canvasContext, text, style);

    // Indicates whether we've reached the end of text or not. Even if the index
    // [i] reaches the end of text, we don't want to stop looping until we hit
    // [LineBreakType.endOfText] because there could be a "\n" at the end of the
    // string and that would mess things up.
    bool reachedEndOfText = false;

    // TODO(flutter_web): Chrome & Safari return more info from [canvasContext.measureText].
    int i = 0;
    while (!reachedEndOfText) {
      final LineBreakResult brk = nextLineBreak(text, i);

      linesCalculator.update(brk);
      minIntrinsicCalculator.update(brk);
      maxIntrinsicCalculator.update(brk);

      i = brk.index;
      if (brk.type == LineBreakType.endOfText) {
        reachedEndOfText = true;
      }
    }

    final double alphabeticBaseline = ruler.alphabeticBaseline;
    final int lineCount = linesCalculator.lines.length;
    final double lineHeight = ruler.lineHeight;
    final double naturalHeight = lineCount * lineHeight;
    final int? maxLines = style.maxLines;
    final double height = maxLines == null
        ? naturalHeight
        : math.min<int>(lineCount, maxLines) * lineHeight;

    final MeasurementResult result = MeasurementResult(
      constraints.width,
      isSingleLine: lineCount == 1,
      alphabeticBaseline: alphabeticBaseline,
      ideographicBaseline: alphabeticBaseline * baselineRatioHack,
      height: height,
      naturalHeight: naturalHeight,
      lineHeight: lineHeight,
      // `minIntrinsicWidth` is the greatest width of text that can't
      // be broken down into multiple lines.
      minIntrinsicWidth: minIntrinsicCalculator.value,
      // `maxIntrinsicWidth` is the width of the widest piece of text
      // that doesn't contain mandatory line breaks.
      maxIntrinsicWidth: maxIntrinsicCalculator.value,
      width: constraints.width,
      lines: linesCalculator.lines,
      placeholderBoxes: <ui.TextBox>[],
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
    );
    return result;
  }

  @override
  double measureSubstringWidth(DomParagraph paragraph, int start, int end) {
    assert(paragraph.plainText != null);
    final String text = paragraph.plainText!;
    final ParagraphGeometricStyle style = paragraph.geometricStyle;
    _canvasContext.font = style.cssFontString;
    return measureSubstring(
      _canvasContext,
      text,
      start,
      end,
      letterSpacing: paragraph.geometricStyle.letterSpacing,
    );
  }

  @override
  ui.TextPosition getTextPositionForOffset(EngineParagraph paragraph,
      ui.ParagraphConstraints? constraints, ui.Offset offset) {
    // TODO(flutter_web): implement.
    return const ui.TextPosition(offset: 0);
  }
}

// These global variables are used to memoize calls to [measureSubstring]. They
// are used to remember the last arguments passed to it, and the last return
// value.
// They are being initialized so that the compiler knows they'll never be null.
int _lastStart = -1;
int _lastEnd = -1;
String _lastText = '';
String _lastCssFont = '';
double _lastWidth = -1;

/// Measures the width of the substring of [text] starting from the index
/// [start] (inclusive) to [end] (exclusive).
///
/// This method assumes that the correct font has already been set on
/// [_canvasContext].
double measureSubstring(
  html.CanvasRenderingContext2D _canvasContext,
  String text,
  int start,
  int end, {
  double? letterSpacing,
}) {
  assert(0 <= start);
  assert(start <= end);
  assert(end <= text.length);

  if (start == end) {
    return 0;
  }

  final String cssFont = _canvasContext.font;
  double width;

  // TODO(mdebbar): Explore caching all widths in a map, not only the last one.
  if (start == _lastStart &&
      end == _lastEnd &&
      text == _lastText &&
      cssFont == _lastCssFont) {
    // Reuse the previously calculated width if all factors that affect width
    // are unchanged. The only exception is letter-spacing. We always add
    // letter-spacing to the width later below.
    width = _lastWidth;
  } else {
    final String sub =
      start == 0 && end == text.length ? text : text.substring(start, end);
    width = _canvasContext.measureText(sub).width!.toDouble();
  }

  _lastStart = start;
  _lastEnd = end;
  _lastText = text;
  _lastCssFont = cssFont;
  _lastWidth = width;

  // Now add letter spacing to the width.
  letterSpacing ??= 0.0;
  if (letterSpacing != 0.0) {
    width += letterSpacing * (end - start);
  }

  // What we are doing here is we are rounding to the nearest 2nd decimal
  // point. So 39.999423 becomes 40, and 11.243982 becomes 11.24.
  // The reason we are doing this is because we noticed that canvas API has a
  // ±0.001 error margin.
  return _roundWidth(width);
}

double _roundWidth(double width) {
  return (width * 100).round() / 100;
}

/// From the substring defined by [text], [start] (inclusive) and [end]
/// (exclusive), exclude trailing characters that satisfy the given [predicate].
///
/// The return value is the new end of the substring after excluding the
/// trailing characters.
int _excludeTrailing(String text, int start, int end, CharPredicate predicate) {
  assert(0 <= start);
  assert(start <= end);
  assert(end <= text.length);

  while (start < end && predicate(text.codeUnitAt(end - 1))) {
    end--;
  }
  return end;
}

/// During the text layout phase, this class splits the lines of text so that it
/// ends up fitting into the given width constraint.
///
/// It implements the Flutter engine's behavior when it comes to handling
/// ellipsis and max lines.
class LinesCalculator {
  LinesCalculator(this._canvasContext, this._paragraph, this._maxWidth);

  final html.CanvasRenderingContext2D _canvasContext;
  final DomParagraph _paragraph;
  final double _maxWidth;

  String? get _text => _paragraph.plainText;
  ParagraphGeometricStyle get _style => _paragraph.geometricStyle;

  /// The lines that have been consumed so far.
  List<EngineLineMetrics> lines = <EngineLineMetrics>[];

  /// The last line break regardless of whether it was optional or mandatory, or
  /// whether we took it or not.
  LineBreakResult _lastBreak =
      const LineBreakResult.sameIndex(0, LineBreakType.mandatory);

  /// The last line break that actually caused a new line to exist.
  LineBreakResult _lastTakenBreak =
      const LineBreakResult.sameIndex(0, LineBreakType.mandatory);

  int get _lineStart => _lastTakenBreak.index;
  int get _chunkStart => _lastBreak.index;
  bool _reachedMaxLines = false;

  double? _cachedEllipsisWidth;
  double get _ellipsisWidth => _cachedEllipsisWidth ??=
      _roundWidth(_canvasContext.measureText(_style.ellipsis!).width! as double);

  bool get hasEllipsis => _style.ellipsis != null;
  bool get unlimitedLines => _style.maxLines == null;

  /// Consumes the next line break opportunity in [_text].
  ///
  /// This method should be called for every line break. As soon as it reaches
  /// the maximum number of lines required
  void update(LineBreakResult brk) {
    final int chunkEnd = brk.index;
    final int chunkEndWithoutNewlines = brk.indexWithoutTrailingNewlines;
    final int chunkEndWithoutSpace = brk.indexWithoutTrailingSpaces;

    // A single chunk of text could be force-broken into multiple lines if it
    // doesn't fit in a single line. That's why we need a loop.
    while (!_reachedMaxLines) {
      final double lineWidth =
          measureSubstringWidth(_lineStart, chunkEndWithoutSpace);

      // The current chunk doesn't reach the maximum width, so we stop here and
      // wait for the next line break.
      if (lineWidth <= _maxWidth) {
        break;
      }

      // If the current chunk starts at the beginning of the line and exceeds
      // [maxWidth], then we will need to force-break it.
      final bool isChunkTooLong = _chunkStart == _lineStart;

      // When ellipsis is set, and maxLines is null, we stop at the first line
      // that exceeds [maxWidth].
      final bool isLastLine = _reachedMaxLines =
          (hasEllipsis && unlimitedLines) ||
              lines.length + 1 == _style.maxLines;

      if (isLastLine && hasEllipsis) {
        // When there's an ellipsis, truncate text to leave enough space for
        // the ellipsis.
        final double availableWidth = _maxWidth - _ellipsisWidth;
        final int breakingPoint = forceBreakSubstring(
          maxWidth: availableWidth,
          start: _lineStart,
          end: chunkEndWithoutSpace,
        );
        final double widthOfResultingLine =
            measureSubstringWidth(_lineStart, breakingPoint) + _ellipsisWidth;
        final double alignOffset = _calculateAlignOffsetForLine(
          paragraph: _paragraph,
          lineWidth: widthOfResultingLine,
          maxWidth: _maxWidth,
        );
        lines.add(EngineLineMetrics.withText(
          _text!.substring(_lineStart, breakingPoint) + _style.ellipsis!,
          startIndex: _lineStart,
          endIndex: chunkEnd,
          endIndexWithoutNewlines: chunkEndWithoutNewlines,
          hardBreak: false,
          width: widthOfResultingLine,
          widthWithTrailingSpaces: widthOfResultingLine,
          left: alignOffset,
          lineNumber: lines.length,
        ));
      } else if (isChunkTooLong) {
        final int breakingPoint = forceBreakSubstring(
          maxWidth: _maxWidth,
          start: _lineStart,
          end: chunkEndWithoutSpace,
        );
        if (breakingPoint == chunkEndWithoutSpace) {
          // We couldn't force-break the chunk any further which means we reached
          // the last character and there isn't enough space for it to fit in
          // its own line. Since this is the last character in the chunk, we
          // don't do anything here and we rely on the next iteration (or the
          // [isHardBreak] check below) to break the line.
          break;
        }
        _addLineBreak(LineBreakResult.sameIndex(
          breakingPoint,
          LineBreakType.opportunity,
        ));
      } else {
        // The control case of current line exceeding [_maxWidth], we break the
        // line.
        _addLineBreak(_lastBreak);
      }
    }

    if (_reachedMaxLines) {
      return;
    }

    if (brk.isHard) {
      _addLineBreak(brk);
    }
    _lastBreak = brk;
  }

  void _addLineBreak(LineBreakResult brk) {
    final int lineNumber = lines.length;
    final double lineWidth =
        measureSubstringWidth(_lineStart, brk.indexWithoutTrailingSpaces);
    final double lineWidthWithTrailingSpaces =
        measureSubstringWidth(_lineStart, brk.indexWithoutTrailingNewlines);
    final double alignOffset = _calculateAlignOffsetForLine(
      paragraph: _paragraph,
      lineWidth: lineWidth,
      maxWidth: _maxWidth,
    );

    final EngineLineMetrics metrics = EngineLineMetrics.withText(
      _text!.substring(_lineStart, brk.indexWithoutTrailingNewlines),
      startIndex: _lineStart,
      endIndex: brk.index,
      endIndexWithoutNewlines: brk.indexWithoutTrailingNewlines,
      hardBreak: brk.isHard,
      width: lineWidth,
      widthWithTrailingSpaces: lineWidthWithTrailingSpaces,
      left: alignOffset,
      lineNumber: lineNumber,
    );
    lines.add(metrics);
    _lastTakenBreak = _lastBreak = brk;
    if (lines.length == _style.maxLines) {
      _reachedMaxLines = true;
    }
  }

  /// Measures the width of a substring of [_text] starting from the index
  /// [start] (inclusive) to [end] (exclusive).
  ///
  /// This method uses [_text], [_style] and [_canvasContext] to perform the
  /// measurement.
  double measureSubstringWidth(int start, int end) {
    return measureSubstring(
      _canvasContext,
      _text!,
      start,
      end,
      letterSpacing: _style.letterSpacing,
    );
  }

  /// In a continuous block of text, finds the point where text can be broken to
  /// fit in the given constraint [maxWidth].
  ///
  /// This always returns at least one character even if there isn't enough
  /// space for it.
  int forceBreakSubstring({
    required double maxWidth,
    required int start,
    required int end,
  }) {
    assert(0 <= start);
    assert(start < end);
    assert(end <= _text!.length);

    // When there's no ellipsis, the breaking point should be at least one
    // character away from [start].
    int low = hasEllipsis ? start : start + 1;
    int high = end;
    do {
      final int mid = (low + high) ~/ 2;
      final double width = measureSubstringWidth(start, mid);
      if (width < maxWidth) {
        low = mid;
      } else if (width > maxWidth) {
        high = mid;
      } else {
        low = high = mid;
      }
    } while (high - low > 1);

    return low;
  }
}

/// During the text layout phase, this class takes care of calculating the
/// minimum intrinsic width of the given text.
class MinIntrinsicCalculator {
  MinIntrinsicCalculator(this._canvasContext, this._text, this._style);

  final html.CanvasRenderingContext2D _canvasContext;
  final String _text;
  final ParagraphGeometricStyle _style;

  /// The value of minimum intrinsic width calculated so far.
  double value = 0.0;
  int _lastChunkEnd = 0;

  /// Consumes the next line break opportunity in [_text].
  ///
  /// As this method gets called, it updates the [value] to the minimum
  /// intrinsic width calculated so far. When the whole text is consumed,
  /// [value] will contain the final minimum intrinsic width.
  void update(LineBreakResult brk) {
    final int chunkEnd = brk.index;
    final double width = measureSubstring(
      _canvasContext,
      _text,
      _lastChunkEnd,
      brk.indexWithoutTrailingSpaces,
      letterSpacing: _style.letterSpacing,
    );
    if (width > value) {
      value = width;
    }
    _lastChunkEnd = chunkEnd;
  }
}

/// During text layout, this class is responsible for calculating the maximum
/// intrinsic width of the given text.
class MaxIntrinsicCalculator {
  MaxIntrinsicCalculator(this._canvasContext, this._text, this._style);

  final html.CanvasRenderingContext2D _canvasContext;
  final String _text;
  final ParagraphGeometricStyle _style;

  /// The value of maximum intrinsic width calculated so far.
  double value = 0.0;
  int _lastHardLineEnd = 0;

  /// Consumes the next line break opportunity in [_text].
  ///
  /// As this method gets called, it updates the [value] to the maximum
  /// intrinsic width calculated so far. When the whole text is consumed,
  /// [value] will contain the final maximum intrinsic width.
  void update(LineBreakResult brk) {
    if (!brk.isHard) {
      return;
    }

    final double lineWidth = measureSubstring(
      _canvasContext,
      _text,
      _lastHardLineEnd,
      brk.indexWithoutTrailingNewlines,
      letterSpacing: _style.letterSpacing,
    );
    if (lineWidth > value) {
      value = lineWidth;
    }
    _lastHardLineEnd = brk.index;
  }
}

/// Calculates the offset necessary for the given line to be correctly aligned.
double _calculateAlignOffsetForLine({
  required DomParagraph paragraph,
  required double lineWidth,
  required double maxWidth,
}) {
  final double emptySpace = maxWidth - lineWidth;
  // WARNING: the [paragraph] may not be laid out yet at this point. This
  // function must not use layout metrics, such as [paragraph.height].
  switch (paragraph.textAlign) {
    case ui.TextAlign.center:
      return emptySpace / 2.0;
    case ui.TextAlign.right:
      return emptySpace;
    case ui.TextAlign.start:
      return paragraph.textDirection == ui.TextDirection.rtl
          ? emptySpace
          : 0.0;
    case ui.TextAlign.end:
      return paragraph.textDirection == ui.TextDirection.rtl
          ? 0.0
          : emptySpace;
    default:
      return 0.0;
  }
}
