import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Follow the phone's light/dark setting: pick the palette and match the system bars.
/// Returns true when the palette changed.
bool syncBrightness() {
  final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  final changed = dark != C.dark;
  C.dark = dark;
  final icons = dark ? Brightness.light : Brightness.dark;
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: C.canvas,
    systemNavigationBarIconBrightness: icons,
  ));
  return changed;
}

ThemeData loftTheme() {
  final scheme = (C.dark ? ColorScheme.dark : ColorScheme.light)(
    surface: C.canvas,
    onSurface: C.t1,
    primary: C.primary,
    onPrimary: C.onPrimary,
    secondary: C.t2,
    error: C.failed,
    outline: C.borderStrong,
    outlineVariant: C.border,
    surfaceContainerHighest: C.raised,
    surfaceContainerHigh: C.raised,
    surfaceContainer: C.surface,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: C.dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.canvas,
    fontFamily: F.sans,
    splashFactory: InkSparkle.splashFactory,
    textTheme: TextTheme(bodyMedium: T.body, bodyLarge: T.body, titleMedium: T.rowTitle, labelLarge: T.button),
    dividerColor: C.border,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.selected,
      contentTextStyle: TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t1),
      actionTextColor: C.t1,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(R.md)), side: BorderSide(color: C.borderStrong)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(R.lg)), side: BorderSide(color: C.borderStrong)),
      titleTextStyle: TextStyle(fontFamily: F.sans, fontSize: 18, fontWeight: FontWeight.w600, color: C.t1),
      contentTextStyle: TextStyle(fontFamily: F.sans, fontSize: 15, height: 1.45, color: C.t2),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: C.surface, modalBackgroundColor: C.surface, showDragHandle: true, dragHandleColor: C.t3),
    popupMenuTheme: PopupMenuThemeData(
      color: C.raised,
      textStyle: TextStyle(fontFamily: F.sans, fontSize: 15, color: C.t1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(R.md)), side: BorderSide(color: C.borderStrong)),
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: C.t1, selectionColor: Color(0x4D0A84FF), selectionHandleColor: C.work),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.onPrimary : C.t3),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.ok : C.selected),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.ok : C.borderStrong),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: C.t2),
  );
}
