// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/bootstrap/browser.dart';
import 'package:test/test.dart';
import 'package:ui/src/engine.dart';
import 'package:ui/ui.dart' as ui;

import '../screenshot.dart';

void main() {
  internalBootstrapBrowserTest(() => testMain);
}

Future<void> testMain() async {
  setUp(() async {
    ui.debugEmulateFlutterTesterEnvironment = true;
    await ui.webOnlyInitializePlatform();
    ui.webOnlyFontCollection.debugRegisterTestFonts();
    await ui.webOnlyFontCollection.ensureFontsLoaded();
  });

  tearDown(() {
    ContextStateHandle.debugEmulateWebKitMaskFilter = false;
  });

  // Regression test for https://github.com/flutter/flutter/issues/55930
  void testMaskFilterBlur({bool isWebkit = false}) {
    final String browser = isWebkit ? 'Safari' : 'Chrome';

    test('renders MaskFilter.blur in $browser', () async {
      const double screenWidth = 800.0;
      const double screenHeight = 150.0;
      const ui.Rect screenRect = ui.Rect.fromLTWH(0, 0, screenWidth, screenHeight);

      ContextStateHandle.debugEmulateWebKitMaskFilter = isWebkit;
      final RecordingCanvas rc = RecordingCanvas(screenRect);
      rc.translate(0, 75);

      final SurfacePaint paint = SurfacePaint()
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 5);

      rc.translate(50, 0);
      rc.drawRect(
        ui.Rect.fromCircle(center: ui.Offset.zero, radius: 30),
        paint,
      );

      rc.translate(100, 0);
      paint.color = ui.Color(0xFF00FF00);
      rc.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromCircle(center: ui.Offset.zero, radius: 30),
          ui.Radius.circular(20),
        ),
        paint,
      );

      rc.translate(100, 0);
      paint.color = ui.Color(0xFF0000FF);
      rc.drawCircle(ui.Offset.zero, 30, paint);

      rc.translate(100, 0);
      paint.color = ui.Color(0xFF00FFFF);
      rc.drawPath(
        SurfacePath()
          ..moveTo(-20, 0)
          ..lineTo(0, -50)
          ..lineTo(20, 0)
          ..lineTo(0, 50)
          ..close(),
        paint,
      );

      rc.translate(100, 0);
      paint.color = ui.Color(0xFFFF00FF);
      rc.drawOval(
        ui.Rect.fromCenter(center: ui.Offset.zero, width: 40, height: 100),
        paint,
      );

      rc.translate(100, 0);
      paint.color = ui.Color(0xFF888800);
      paint.strokeWidth = 5;
      rc.drawLine(
        ui.Offset(-20, -50),
        ui.Offset(20, 50),
        paint,
      );

      rc.translate(100, 0);
      paint.color = ui.Color(0xFF888888);
      rc.drawDRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromCircle(center: ui.Offset.zero, radius: 35),
          ui.Radius.circular(20),
        ),
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromCircle(center: ui.Offset.zero, radius: 15),
          ui.Radius.circular(7),
        ),
        paint,
      );

      rc.translate(100, 0);
      paint.color = ui.Color(0xFF6500C9);
      rc.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(<double>[-10, -10, -10, 10, 10, -10, 10, 10]),
        paint,
      );

      await canvasScreenshot(rc, 'mask_filter_$browser', region: screenRect);
    });

    test('renders transformed MaskFilter.blur in $browser', () async {
      const double screenWidth = 300.0;
      const double screenHeight = 300.0;
      const ui.Rect screenRect = ui.Rect.fromLTWH(0, 0, screenWidth, screenHeight);

      ContextStateHandle.debugEmulateWebKitMaskFilter = isWebkit;
      final RecordingCanvas rc = RecordingCanvas(screenRect);
      rc.translate(150, 150);

      final SurfacePaint paint = SurfacePaint()
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 5);

      final List<ui.Color> colors = <ui.Color>[
        ui.Color(0xFF000000),
        ui.Color(0xFF00FF00),
        ui.Color(0xFF0000FF),
        ui.Color(0xFF00FFFF),
        ui.Color(0xFFFF00FF),
        ui.Color(0xFF888800),
        ui.Color(0xFF888888),
        ui.Color(0xFF6500C9),
      ];

      for (ui.Color color in colors) {
        paint.color = color;
        rc.rotate(math.pi / 4);
        rc.drawRect(
          ui.Rect.fromCircle(center: const ui.Offset(90, 0), radius: 20),
          paint,
        );
      }

      await canvasScreenshot(rc, 'mask_filter_transformed_$browser',
          region: screenRect);
    });
  }

  testMaskFilterBlur(isWebkit: false);
  testMaskFilterBlur(isWebkit: true);

  for (int testDpr in <int>[1, 2, 4]) {
    test('MaskFilter.blur blurs correctly for device-pixel ratio $testDpr', () async {
      window.debugOverrideDevicePixelRatio(testDpr.toDouble());
      const ui.Rect screenRect = ui.Rect.fromLTWH(0, 0, 150, 150);

      final RecordingCanvas rc = RecordingCanvas(screenRect);
      rc.translate(0, 75);

      final SurfacePaint paint = SurfacePaint()
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, 5);

      rc.translate(75, 0);
      rc.drawRect(
        ui.Rect.fromCircle(center: ui.Offset.zero, radius: 30),
        paint,
      );

      await canvasScreenshot(rc, 'mask_filter_blur_dpr_$testDpr',
          region: screenRect);
      window.debugOverrideDevicePixelRatio(1.0);
    });
  }
}
