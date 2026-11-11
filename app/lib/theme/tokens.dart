// Design tokens from the Figma file "Agent desk",
// Design system page variables. Dark only.
import 'package:flutter/widgets.dart';

abstract final class C {
  static const canvas = Color(0xFF0F1012); // bg/canvas
  static const surface = Color(0xFF15171A); // bg/surface
  static const raised = Color(0xFF1C1F23); // bg/raised
  static const selected = Color(0xFF262A2F); // bg/selected
  static const border = Color(0xFF24272C); // border/default
  static const borderStrong = Color(0xFF30343A); // border/strong
  static const t1 = Color(0xFFEDEEF0); // text/primary
  static const t2 = Color(0xFFA4A8AF); // text/secondary
  static const t3 = Color(0xFF6E737B); // text/muted
  static const onPrimary = Color(0xFF0F1012); // text/on-primary
  static const primary = Color(0xFFEDEEF0); // action/primary
  static const work = Color(0xFF5B8DFF); // account/work
  static const personal = Color(0xFF46C07D); // account/personal
  static const needs = Color(0xFFF2B544); // status/needs
  static const failed = Color(0xFFF0685A); // status/failed

  static const ok = Color(0xFF46C07D); // connected / switch on
}

abstract final class S {
  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 20.0, s6 = 24.0, s8 = 32.0;
}

abstract final class R {
  static const sm = 6.0, md = 10.0, lg = 14.0, full = 999.0;
}

abstract final class F {
  static const sans = 'Geist';
  static const mono = 'GeistMono';
}

/// Mobile type scale (Figma Mobile page).
abstract final class T {
  static const appTitle = TextStyle(fontFamily: F.sans, fontSize: 18, fontWeight: FontWeight.w600, color: C.t1);
  static const screenTitle = TextStyle(fontFamily: F.sans, fontSize: 17, fontWeight: FontWeight.w600, color: C.t1);
  static const body = TextStyle(fontFamily: F.sans, fontSize: 16, height: 24 / 16, color: C.t1);
  static const question = TextStyle(fontFamily: F.sans, fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w600, color: C.t1);
  static const rowTitle = TextStyle(fontFamily: F.sans, fontSize: 15, height: 1.5, fontWeight: FontWeight.w500, color: C.t1);
  static const button = TextStyle(fontFamily: F.sans, fontSize: 15, fontWeight: FontWeight.w500, color: C.t1);
  static const secondary = TextStyle(fontFamily: F.sans, fontSize: 13, height: 1.45, color: C.t2);
  static const label = TextStyle(fontFamily: F.sans, fontSize: 13, fontWeight: FontWeight.w500, color: C.t2);
  static const caption = TextStyle(fontFamily: F.sans, fontSize: 12, color: C.t3);
  static const mono12 = TextStyle(fontFamily: F.mono, fontSize: 12, height: 1.3, color: C.t3);
  static const mono13 = TextStyle(fontFamily: F.mono, fontSize: 13, color: C.t2);
}
