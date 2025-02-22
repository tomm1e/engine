// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;

import 'package:test/bootstrap/browser.dart';
import 'package:test/test.dart';
import 'package:ui/src/engine.dart';
import 'package:ui/ui.dart';

import '../../matchers.dart';

const MethodCodec codec = StandardMethodCodec();
final EngineSingletonFlutterWindow window = EngineSingletonFlutterWindow(0, EnginePlatformDispatcher.instance);

void main() {
  internalBootstrapBrowserTest(() => testMain);
}

void testMain() {
  late PersistedPlatformView view;

  group('PersistedPlatformView', () {
    setUp(() async {
      platformViewRegistry.registerViewFactory(
        'test-0',
        (int viewId) => html.DivElement(),
      );
      platformViewRegistry.registerViewFactory(
        'test-1',
        (int viewId) => html.DivElement(),
      );
      // Ensure the views are created...
      await Future.wait(<Future<void>>[
        _createPlatformView(0, 'test-0'),
        _createPlatformView(1, 'test-1'),
      ]);
      view = PersistedPlatformView(0, 0, 0, 100, 100)..build();
    });

    group('update', () {
      test('throws assertion error if called with different viewIds', () {
        final PersistedPlatformView differentView = PersistedPlatformView(1, 1, 1, 100, 100)..build();
        expect(() {
          view.update(differentView);
        }, throwsAssertionError);
      });
    });

    group('canUpdateAsMatch', () {
      test('returns true when viewId is the same', () {
        final PersistedPlatformView sameView = PersistedPlatformView(0, 1, 1, 100, 100)..build();
        expect(view.canUpdateAsMatch(sameView), isTrue);
      });

      test('returns false when viewId is different', () {
        final PersistedPlatformView differentView = PersistedPlatformView(1, 1, 1, 100, 100)..build();
        expect(view.canUpdateAsMatch(differentView), isFalse);
      });

      test('returns false when other view is not a PlatformView', () {
        final PersistedOpacity anyView = PersistedOpacity(null, 1, Offset(0, 0))..build();
        expect(view.canUpdateAsMatch(anyView), isFalse);
      });
    });

    group('createElement', () {
      test('creates slot element that can receive pointer events', () {
        final html.Element element = view.createElement();

        expect(element.tagName, equalsIgnoringCase('flt-platform-view-slot'));
        expect(element.style.pointerEvents, 'auto');
      });
    });
  });
}

// Sends a platform message to create a Platform View with the given id and viewType.
Future<void> _createPlatformView(int id, String viewType) {
  final Completer<void> completer = Completer<void>();
  window.sendPlatformMessage(
    'flutter/platform_views',
    codec.encodeMethodCall(MethodCall(
      'create',
      <String, dynamic>{
        'id': id,
        'viewType': viewType,
      },
    )),
    (dynamic _) => completer.complete(),
  );
  return completer.future;
}
