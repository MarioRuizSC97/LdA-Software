import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

/// Applies [size] at device pixel ratio 1 and [textScale], reset on teardown.
void useViewport(WidgetTester tester, Size size, [double textScale = 1]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
