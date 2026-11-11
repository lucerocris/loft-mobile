import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData loftTheme() {
  const scheme = ColorScheme.dark(
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
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.canvas,
    fontFamily: F.sans,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(bodyMedium: T.body, bodyLarge: T.body, titleMedium: T.rowTitle, labelLarge: T.button),
    dividerColor: C.border,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: C.selected,
      contentTextStyle: TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t1),
      actionTextColor: C.t1,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(R.md)), side: BorderSide(color: C.borderStrong)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: C.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(R.lg)), side: BorderSide(color: C.borderStrong)),
      titleTextStyle: TextStyle(fontFamily: F.sans, fontSize: 18, fontWeight: FontWeight.w600, color: C.t1),
      contentTextStyle: TextStyle(fontFamily: F.sans, fontSize: 15, height: 1.45, color: C.t2),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: C.surface, modalBackgroundColor: C.surface, showDragHandle: true, dragHandleColor: C.t3),
    popupMenuTheme: const PopupMenuThemeData(
      color: C.raised,
      textStyle: TextStyle(fontFamily: F.sans, fontSize: 15, color: C.t1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(R.md)), side: BorderSide(color: C.borderStrong)),
    ),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: C.t1, selectionColor: Color(0x4D5B8DFF), selectionHandleColor: C.work),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.onPrimary : C.t3),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.ok : C.selected),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.ok : C.borderStrong),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.t2),
  );
}
