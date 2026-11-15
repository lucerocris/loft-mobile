import 'package:xterm/xterm.dart';

/// Mouse handler for the attach terminal.
///
/// `claude attach` runs full screen (alternate buffer, no local scrollback) and
/// turns on SGR mouse tracking, so a finger drag can only scroll the
/// conversation if it reaches Claude as mouse-wheel reports. xterm.dart 4.0
/// encodes wheel buttons as 68..71 (64 + 4..7), but the standard codes are
/// 64..67; 68 is "shift + wheel up", which Claude ignores. So drags did nothing.
/// This sends the standard codes and leaves clicks to the package's handler.
class LoftMouseHandler implements TerminalMouseHandler {
  const LoftMouseHandler();

  static const _wheel = {
    TerminalMouseButton.wheelUp: 64,
    TerminalMouseButton.wheelDown: 65,
    TerminalMouseButton.wheelLeft: 66,
    TerminalMouseButton.wheelRight: 67,
  };

  @override
  String? call(TerminalMouseEvent event) {
    final code = _wheel[event.button];
    if (code == null) return defaultMouseHandler(event);
    switch (event.state.mouseMode) {
      case MouseMode.none:
      case MouseMode.clickOnly:
        return null;
      case MouseMode.upDownScroll:
      case MouseMode.upDownScrollDrag:
      case MouseMode.upDownScrollMove:
        break;
    }
    if (event.buttonState == TerminalMouseButtonState.up) return null; // wheels have no release
    final x = event.position.x + 1, y = event.position.y + 1;
    switch (event.state.mouseReportMode) {
      case MouseReportMode.sgr:
        return '\x1b[<$code;$x;${y}M';
      case MouseReportMode.urxvt:
        return '\x1b[${32 + code};$x;${y}M';
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        final limit = event.state.mouseReportMode == MouseReportMode.normal ? 223 : 2015;
        String pos(int v) => v > limit ? '\x00' : String.fromCharCode(32 + v);
        return '\x1b[M${String.fromCharCode(32 + code)}${pos(x)}${pos(y)}';
    }
  }
}
