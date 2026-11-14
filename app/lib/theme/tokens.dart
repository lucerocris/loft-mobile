// Design tokens from the Figma file "Loft — Redesign", Mobile page, option M1 "Glass"
// (variable collection "Loft", modes Dark / Light). The app follows the phone's
// light/dark setting: LoftApp sets [C.dark] and rebuilds when it changes.
import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

abstract final class C {
  /// Which palette the getters below return. Set by LoftApp from the platform brightness.
  static bool dark = true;
  static Color _p(int d, int l) => Color(dark ? d : l);

  static Color get canvas => _p(0xFF171C26, 0xFFE1E8F2); // bg/backdrop: what the glass floats on
  static Color get surface => _p(0xFF22262E, 0xFFF4F6FA); // sheets, dialogs, fields
  static Color get raised => _p(0xFF2C2E34, 0xFFFFFFFF); // menus, secondary buttons, selected segment
  static Color get selected => _p(0x1AFFFFFF, 0x0F000000); // pressed / selected fill
  static Color get border => _p(0x17FFFFFF, 0x17000000);
  static Color get borderStrong => _p(0x29FFFFFF, 0x24000000);
  static Color get t1 => _p(0xFFF2F2F7, 0xFF1D1D1F);
  static Color get t2 => _p(0xFFA1A1A8, 0xFF5F5F66);
  static Color get t3 => _p(0xFF75757C, 0xFF86868D);
  static Color get onPrimary => _p(0xFF1D1D1F, 0xFFFFFFFF);
  static Color get primary => _p(0xFFF2F2F7, 0xFF1D1D1F); // graphite accent
  static Color get needs => _p(0xFFFFB340, 0xFFA65A00); // status text
  static Color get needsDot => _p(0xFFFFB340, 0xFFE89A00);
  static Color get failed => _p(0xFFFF453A, 0xFFD70015);
  static Color get ok => _p(0xFF30D158, 0xFF248A3D);

  // Glass: the floating layer (header buttons, chips, cards, composer, New task).
  static Color get glass => _p(0x9E282A30, 0x9EFFFFFF);
  static Color get glassBorder => _p(0x24FFFFFF, 0x14000000);
  static double get shadowAlpha => dark ? .30 : .12;

  // Fallback account colors (Apple system blue / green), used before the laptop sends its list.
  static const work = Color(0xFF0A84FF);
  static const personal = Color(0xFF30D158);
}

abstract final class S {
  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 20.0, s6 = 24.0, s8 = 32.0;
}

abstract final class R {
  static const sm = 7.0, md = 10.0, lg = 16.0, full = 999.0;
}

abstract final class F {
  static const sans = 'Geist';
  static const mono = 'GeistMono';
}

/// Mobile type scale (Figma Mobile page).
abstract final class T {
  static TextStyle get appTitle => TextStyle(fontFamily: F.sans, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -.5, color: C.t1);
  static TextStyle get screenTitle => TextStyle(fontFamily: F.sans, fontSize: 17, fontWeight: FontWeight.w600, color: C.t1);
  static TextStyle get body => TextStyle(fontFamily: F.sans, fontSize: 16, height: 24 / 16, color: C.t1);
  static TextStyle get question => TextStyle(fontFamily: F.sans, fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w700, letterSpacing: -.2, color: C.t1);
  static TextStyle get rowTitle => TextStyle(fontFamily: F.sans, fontSize: 16, height: 1.45, fontWeight: FontWeight.w500, color: C.t1);
  static TextStyle get button => TextStyle(fontFamily: F.sans, fontSize: 15, fontWeight: FontWeight.w500, color: C.t1);
  static TextStyle get secondary => TextStyle(fontFamily: F.sans, fontSize: 14, height: 1.4, color: C.t2);
  static TextStyle get label => TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w600, color: C.t2);
  static TextStyle get caption => TextStyle(fontFamily: F.sans, fontSize: 12, color: C.t3);
  static TextStyle get mono12 => TextStyle(fontFamily: F.mono, fontSize: 12, height: 1.3, color: C.t3);
  static TextStyle get mono13 => TextStyle(fontFamily: F.mono, fontSize: 13, color: C.t2);
}

/// Figma M1 "Glass": a translucent, blurred surface with a hairline and a soft shadow.
/// Use it only on the floating layer, never behind long reading content.
class Glass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final bool lifted;
  final Color? border;
  final double borderWidth;
  const Glass({super.key, required this.child, this.radius = const BorderRadius.all(Radius.circular(R.full)), this.lifted = false, this.border, this.borderWidth = 1});

  @override
  Widget build(BuildContext context) {
    final a = C.shadowAlpha;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: [
        BoxShadow(color: Color.fromRGBO(0, 0, 0, lifted ? a : a * .6), blurRadius: lifted ? 30 : 10, offset: Offset(0, lifted ? 10 : 3)),
      ]),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(color: C.glass, borderRadius: radius, border: Border.all(color: border ?? C.glassBorder, width: borderWidth)),
            child: child,
          ),
        ),
      ),
    );
  }
}
