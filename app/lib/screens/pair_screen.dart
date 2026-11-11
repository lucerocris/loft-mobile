import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/loft_client.dart';
import '../data/pairing.dart';
import '../state/conn.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// Figma 1 · Pair: scan the desktop QR, or paste address + pairing code.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});
  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  final _host = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false, _scanning = false;
  String? _error;
  MobileScannerController? _scanner;

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    _scanner?.dispose();
    super.dispose();
  }

  Future<void> _connect(Pairing p) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final c = LoftClient(p);
    try {
      final ping = await c.ping();
      final paired = Pairing(host: p.host, token: p.token, name: ping.host.isEmpty ? p.name : ping.host);
      await PairingStore.save(paired);
      ref.read(pairingProvider.notifier).state = paired;
      if (mounted) context.go('/');
    } on LoftError catch (e) {
      setState(() => _error = e.unauthorized ? 'That code isn\'t valid (or was revoked). Make a new one on the laptop.' : e.message);
    } finally {
      c.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _manual() {
    final host = Pairing.normalizeHost(_host.text);
    final code = _code.text.trim();
    if (host == null) return setState(() => _error = 'Enter the address Loft shows, like 100.64.0.10:7717.');
    if (code.isEmpty) return setState(() => _error = 'Paste the pairing code from Loft on the laptop.');
    final fromUri = Pairing.fromUri(code); // a pasted loft:// link works too
    _connect(fromUri ?? Pairing(host: host, token: code));
  }

  void _startScan() {
    _scanner ??= MobileScannerController(formats: const [BarcodeFormat.qrCode]);
    setState(() => _scanning = true);
  }

  void _onDetect(BarcodeCapture cap) {
    if (_busy) return;
    for (final b in cap.barcodes) {
      final p = Pairing.fromUri(b.rawValue ?? '');
      if (p != null) {
        HapticFeedback.mediumImpact();
        _scanner?.stop();
        setState(() => _scanning = false);
        _host.text = p.host;
        _connect(p);
        return;
      }
    }
  }

  InputDecoration _input(String hint, {Widget? suffix}) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontFamily: F.mono, fontSize: 15, color: C.t3),
        filled: true,
        fillColor: C.raised,
        contentPadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
        suffixIcon: suffix,
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.t3)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: S.s6), children: [
              const SizedBox(height: S.s4),
              const Row(children: [LoftMark(size: 24), SizedBox(width: S.s2), Text('loft', style: T.appTitle)]),
              const SizedBox(height: S.s6),
              const Text('Connect to your laptop', style: TextStyle(fontFamily: F.sans, fontSize: 24, fontWeight: FontWeight.w600, color: C.t1, letterSpacing: -.2)),
              const SizedBox(height: S.s2),
              const Text('On the laptop, open Loft and choose Pair phone. Point the camera at the code it shows.', style: TextStyle(fontFamily: F.sans, fontSize: 15, height: 22 / 15, color: C.t2)),
              const SizedBox(height: S.s6),
              _scannerBox(),
              const SizedBox(height: S.s6),
              const Row(children: [
                Expanded(child: Divider(color: C.border, height: 1)),
                Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('or enter it', style: T.caption)),
                Expanded(child: Divider(color: C.border, height: 1)),
              ]),
              const SizedBox(height: S.s6),
              const Text('Address', style: TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t2)),
              const SizedBox(height: S.s2),
              TextField(controller: _host, keyboardType: TextInputType.url, autocorrect: false, style: const TextStyle(fontFamily: F.mono, fontSize: 15, color: C.t1), decoration: _input('100.64.0.10:7717')),
              const SizedBox(height: S.s6),
              const Text('Pairing code', style: TextStyle(fontFamily: F.sans, fontSize: 14, color: C.t2)),
              const SizedBox(height: S.s2),
              TextField(
                controller: _code,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: F.mono, fontSize: 15, color: C.t1),
                decoration: _input('paste from Loft on the laptop',
                    suffix: IconButton(
                      tooltip: 'Paste',
                      icon: const Icon(LucideIcons.clipboard, size: 20, color: C.t2),
                      onPressed: () async {
                        final d = await Clipboard.getData('text/plain');
                        if (d?.text != null) _code.text = d!.text!.trim();
                      },
                    )),
                onSubmitted: (_) => _manual(),
              ),
              if (_error != null) ...[
                const SizedBox(height: S.s3),
                Text(_error!, style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.failed)),
              ],
              const SizedBox(height: S.s6),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(S.s6, S.s2, S.s6, S.s3),
            child: Column(children: [
              SizedBox(width: double.infinity, child: Btn('Connect', onTap: _manual, kind: BtnKind.primary, busy: _busy)),
              const SizedBox(height: S.s3),
              const Text('Only over your tailnet. Unpair from Loft on the laptop anytime.', textAlign: TextAlign.center, style: T.caption),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _scannerBox() {
    final frame = Container(
      height: 260,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.border), borderRadius: BorderRadius.circular(R.lg)),
      child: _scanning && _scanner != null
          ? Stack(fit: StackFit.expand, children: [
              MobileScanner(controller: _scanner!, onDetect: _onDetect, errorBuilder: (c, e) => Center(child: Text('Camera unavailable: ${e.errorCode.name}', style: T.caption))),
              const Center(child: _Corners(size: 180)),
            ])
          : InkWell(
              onTap: _startScan,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const _Corners(size: 92),
                const SizedBox(height: S.s4),
                Text(_busy ? 'Connecting…' : 'Tap to scan a Loft code', style: const TextStyle(fontFamily: F.sans, fontSize: 13, color: C.t3)),
              ]),
            ),
    );
    return Semantics(button: true, label: 'Scan the pairing code', child: frame);
  }
}

class _Corners extends StatelessWidget {
  final double size;
  const _Corners({required this.size});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _CornerPainter());
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = C.t1
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final l = s.width * .24, r = 10.0;
    for (final (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (s.width, 0.0, -1.0, 1.0), (0.0, s.height, 1.0, -1.0), (s.width, s.height, -1.0, -1.0)]) {
      final path = Path()
        ..moveTo(x, y + dy * l)
        ..lineTo(x, y + dy * r)
        ..quadraticBezierTo(x, y, x + dx * r, y)
        ..lineTo(x + dx * l, y);
      canvas.drawPath(path, p);
    }
    canvas.drawLine(Offset(s.width * .22, s.height / 2), Offset(s.width * .78, s.height / 2), p..color = C.t2);
  }

  @override
  bool shouldRepaint(_) => false;
}
