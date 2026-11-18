import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// [AppSizes] provides adaptive and responsive sizing utilities for the entire app.
/// It enables your app UI (widths, heights, font sizes, padding, spacing) to scale
/// smoothly across all mobile devices, tablets, foldables, and desktops.
class AppSizes {
  AppSizes._();

  /// Standard reference design canvas size (Figma/Adobe XD base dimensions).
  /// By default, based on 375 x 812 (standard iPhone/Android mobile size).
  static Size designSize = const Size(375, 812);

  // Screen metrics
  static double screenWidth = 375.0;
  static double screenHeight = 812.0;
  static double pixelRatio = 1.0;
  static double statusBarHeight = 0.0;
  static double bottomBarHeight = 0.0;
  static double textScaleFactor = 1.0;
  static Orientation orientation = Orientation.portrait;

  // Scale ratios
  static double _scaleWidth = 1.0;
  static double _scaleHeight = 1.0;
  static double _scaleFactor = 1.0;
  static bool _initialized = false;

  /// Breakpoints
  static const double mobileBreakpoint = 600.0;
  static const double tabletBreakpoint = 1024.0;

  /// Initializes [AppSizes] using [BuildContext].
  /// Recommended to call inside `MaterialApp.builder` or in the root widget's `build` method.
  static void init(BuildContext context, {Size? baseDesignSize}) {
    if (baseDesignSize != null) {
      designSize = baseDesignSize;
    }

    final mediaQuery = MediaQuery.of(context);
    _updateMetrics(
      size: mediaQuery.size,
      devicePixelRatio: mediaQuery.devicePixelRatio,
      padding: mediaQuery.padding,
      viewPadding: mediaQuery.viewPadding,
      deviceOrientation: mediaQuery.orientation,
      textScaler: mediaQuery.textScaler,
    );
  }

  /// Internal metric updater
  static void _updateMetrics({
    required Size size,
    required double devicePixelRatio,
    required EdgeInsets padding,
    required EdgeInsets viewPadding,
    required Orientation deviceOrientation,
    required TextScaler textScaler,
  }) {
    screenWidth = size.width;
    screenHeight = size.height;
    pixelRatio = devicePixelRatio;
    statusBarHeight = padding.top;
    bottomBarHeight = padding.bottom;
    orientation = deviceOrientation;
    textScaleFactor = textScaler.scale(1.0);

    // Calculate scale factor relative to design canvas
    _scaleWidth = screenWidth / designSize.width;
    _scaleHeight = screenHeight / designSize.height;

    // Use minimum scale to prevent disproportionate stretching on tablets/desktops
    _scaleFactor = math.min(_scaleWidth, _scaleHeight);

    // Limit maximum scale on very large screens (e.g. iPad, desktop) so UI elements stay balanced
    if (_scaleFactor > 1.8) {
      _scaleFactor = 1.8;
    }

    _initialized = true;
  }

  /// Ensures fallback initialization from platform dispatcher if called before widget build
  static void _ensureInitialized() {
    if (_initialized) return;

    try {
      final view = ui.PlatformDispatcher.instance.views.isNotEmpty
          ? ui.PlatformDispatcher.instance.views.first
          : null;

      if (view != null && view.physicalSize.width > 0) {
        final physicalSize = view.physicalSize;
        final dpr = view.devicePixelRatio > 0 ? view.devicePixelRatio : 1.0;
        final logicalSize = Size(physicalSize.width / dpr, physicalSize.height / dpr);

        _updateMetrics(
          size: logicalSize,
          devicePixelRatio: dpr,
          padding: EdgeInsets.fromViewPadding(view.padding, dpr),
          viewPadding: EdgeInsets.fromViewPadding(view.viewPadding, dpr),
          deviceOrientation: logicalSize.width > logicalSize.height
              ? Orientation.landscape
              : Orientation.portrait,
          textScaler: TextScaler.noScaling,
        );
      }
    } catch (_) {
      // Fallback to default design dimensions
    }
  }

  // --- Scaled Dimensions ---

  /// Scaled width based on design canvas width
  static double w(num size) {
    _ensureInitialized();
    return size * _scaleWidth;
  }

  /// Scaled height based on design canvas height
  static double h(num size) {
    _ensureInitialized();
    return size * _scaleHeight;
  }

  /// Scaled font size (adaptive to screen size and user's text accessibility settings)
  static double sp(num fontSize, {bool allowFontScaling = true}) {
    _ensureInitialized();
    final scaled = fontSize * _scaleFactor;
    return allowFontScaling ? (scaled * textScaleFactor) : scaled;
  }

  /// Scaled radius for borders and cards
  static double r(num radius) {
    _ensureInitialized();
    return radius * _scaleFactor;
  }

  /// Percentage of screen width (value between 0 and 100)
  /// Example: `AppSizes.percentWidth(50)` -> 50% of screen width
  static double percentWidth(num percent) {
    _ensureInitialized();
    return (percent / 100.0) * screenWidth;
  }

  /// Percentage of screen height (value between 0 and 100)
  /// Example: `AppSizes.percentHeight(30)` -> 30% of screen height
  static double percentHeight(num percent) {
    _ensureInitialized();
    return (percent / 100.0) * screenHeight;
  }

  // --- Device & Orientation Checks ---

  static bool get isMobile {
    _ensureInitialized();
    return screenWidth < mobileBreakpoint;
  }

  static bool get isTablet {
    _ensureInitialized();
    return screenWidth >= mobileBreakpoint && screenWidth < tabletBreakpoint;
  }

  static bool get isDesktop {
    _ensureInitialized();
    return screenWidth >= tabletBreakpoint;
  }

  static bool get isPortrait {
    _ensureInitialized();
    return orientation == Orientation.portrait;
  }

  static bool get isLandscape {
    _ensureInitialized();
    return orientation == Orientation.landscape;
  }

  // --- Spacing Widgets (Adaptive SizedBox) ---

  /// Vertical space (SizedBox with scaled height)
  static Widget verticalSpace(num height) => SizedBox(height: h(height));

  /// Horizontal space (SizedBox with scaled width)
  static Widget horizontalSpace(num width) => SizedBox(width: w(width));

  // --- Standard Spacing Presets ---

  static double get xs => r(4);
  static double get sm => r(8);
  static double get md => r(16);
  static double get lg => r(24);
  static double get xl => r(32);
  static double get xxl => r(48);

  // --- Responsive Padding Helpers ---

  static EdgeInsets paddingAll(num value) => EdgeInsets.all(r(value));

  static EdgeInsets paddingSymmetric({num horizontal = 0, num vertical = 0}) =>
      EdgeInsets.symmetric(
        horizontal: w(horizontal),
        vertical: h(vertical),
      );

  static EdgeInsets paddingOnly({
    num left = 0,
    num top = 0,
    num right = 0,
    num bottom = 0,
  }) =>
      EdgeInsets.only(
        left: w(left),
        top: h(top),
        right: w(right),
        bottom: h(bottom),
      );
}

/// Extension on [num] to allow intuitive syntax like `20.w`, `50.h`, `16.sp`, `12.r`
extension ResponsiveNumExtension on num {
  /// Scaled width: `20.w`
  double get w => AppSizes.w(this);

  /// Scaled height: `40.h`
  double get h => AppSizes.h(this);

  /// Scaled font size: `16.sp`
  double get sp => AppSizes.sp(this);

  /// Scaled border radius: `8.r`
  double get r => AppSizes.r(this);

  /// Percentage of screen width: `50.pw` (50% of screen width)
  double get pw => AppSizes.percentWidth(this);

  /// Percentage of screen height: `25.ph` (25% of screen height)
  double get ph => AppSizes.percentHeight(this);

  /// Adaptive vertical spacing widget: `16.verticalSpace`
  Widget get verticalSpace => AppSizes.verticalSpace(this);

  /// Adaptive horizontal spacing widget: `16.horizontalSpace`
  Widget get horizontalSpace => AppSizes.horizontalSpace(this);
}

/// Extension on [BuildContext] for responsive access and media queries
extension ResponsiveContextExtension on BuildContext {
  /// Screen size info
  Size get screenSize => MediaQuery.sizeOf(this);
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;
  double get pixelRatio => MediaQuery.devicePixelRatioOf(this);
  Orientation get orientation => MediaQuery.orientationOf(this);

  /// Safe area insets
  EdgeInsets get viewPadding => MediaQuery.viewPaddingOf(this);
  EdgeInsets get padding => MediaQuery.paddingOf(this);
  double get statusBarHeight => MediaQuery.paddingOf(this).top;
  double get bottomBarHeight => MediaQuery.paddingOf(this).bottom;

  /// Breakpoint checks
  bool get isMobile => screenWidth < AppSizes.mobileBreakpoint;
  bool get isTablet =>
      screenWidth >= AppSizes.mobileBreakpoint &&
      screenWidth < AppSizes.tabletBreakpoint;
  bool get isDesktop => screenWidth >= AppSizes.tabletBreakpoint;
  bool get isPortrait => orientation == Orientation.portrait;
  bool get isLandscape => orientation == Orientation.landscape;

  /// Scaled sizes directly using context
  double w(num size) => AppSizes.w(size);
  double h(num size) => AppSizes.h(size);
  double sp(num size) => AppSizes.sp(size);
  double r(num size) => AppSizes.r(size);

  /// Percentage helpers
  double percentWidth(num percent) => (percent / 100.0) * screenWidth;
  double percentHeight(num percent) => (percent / 100.0) * screenHeight;
}

/// A responsive widget builder that renders different widgets based on the screen size
class ResponsiveLayout extends StatelessWidget {
  final Widget mobile;
  final Widget? tablet;
  final Widget? desktop;

  const ResponsiveLayout({
    super.key,
    required this.mobile,
    this.tablet,
    this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= AppSizes.tabletBreakpoint && desktop != null) {
          return desktop!;
        }
        if (constraints.maxWidth >= AppSizes.mobileBreakpoint && tablet != null) {
          return tablet!;
        }
        return mobile;
      },
    );
  }
}
