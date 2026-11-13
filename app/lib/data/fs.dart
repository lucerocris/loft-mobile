/// Folder browsing for New task: `GET /api/fs?path=<path>[&hidden=1]` on Loft.
library;

/// One sub-folder in a listing.
class FsDir {
  final String name;
  /// Absolute path on the laptop.
  final String path;
  /// The path as Loft shows it ("~/clients/acme-web").
  final String display;
  /// A git repository (has .git).
  final bool git;
  /// Looks like a web project (Loft can run its dev server in the browser).
  final bool web;
  const FsDir({required this.name, required this.path, required this.display, this.git = false, this.web = false});

  factory FsDir.fromJson(Map<String, dynamic> j) {
    final path = '${j['path'] ?? ''}';
    final display = '${j['display'] ?? path}';
    final name = '${j['name'] ?? ''}';
    return FsDir(
      name: name.isNotEmpty ? name : lastSegment(display),
      path: path.isNotEmpty ? path : display,
      display: display.isNotEmpty ? display : path,
      git: j['git'] == true,
      web: j['web'] == true,
    );
  }
}

/// One folder's listing.
class FsListing {
  final String path, display;
  /// The folder above, as a path to request; null at home (or the top).
  final String? parent;
  final List<FsDir> dirs;
  /// Recently used folders; the server sends them at home only.
  final List<FsDir> recent;
  /// The server stopped listing early (very large folder).
  final bool truncated;
  const FsListing({required this.path, required this.display, this.parent, this.dirs = const [], this.recent = const [], this.truncated = false});

  bool get atHome => parent == null;

  factory FsListing.fromJson(Map<String, dynamic> j) {
    final path = '${j['path'] ?? '~'}';
    final p = j['parent'];
    return FsListing(
      path: path,
      display: '${j['display'] ?? path}',
      parent: p is String && p.isNotEmpty ? p : null,
      dirs: [for (final d in (j['dirs'] as List? ?? const [])) if (d is Map) FsDir.fromJson(d.cast<String, dynamic>())],
      // Items like `dirs` (Loft's loft/fs.py); plain display strings are accepted too.
      recent: [
        for (final r in (j['recent'] as List? ?? const []))
          if (r is Map)
            FsDir.fromJson(r.cast<String, dynamic>())
          else if (r is String && r.isNotEmpty)
            FsDir(name: lastSegment(r), path: r, display: r),
      ],
      truncated: j['truncated'] == true,
    );
  }

  /// The folders whose name contains [filter] (case-insensitive).
  List<FsDir> filtered(String filter) {
    final f = filter.trim().toLowerCase();
    if (f.isEmpty) return dirs;
    return [for (final d in dirs) if (d.name.toLowerCase().contains(f)) d];
  }
}

String lastSegment(String p) {
  final t = p.replaceAll(RegExp(r'/+$'), '');
  if (t.isEmpty) return '/';
  final i = t.lastIndexOf('/');
  return i < 0 ? t : t.substring(i + 1);
}

/// A breadcrumb step: the label to show and the path to request for it.
typedef Crumb = ({String label, String path});

/// "~/clients/acme-web" -> [~, clients, acme-web], each with the path that opens it.
/// Absolute paths ("/srv/x") start at "/".
List<Crumb> breadcrumbs(String display) {
  final d = display.trim().replaceAll(RegExp(r'/+$'), '');
  if (d.isEmpty || d == '~') return [(label: '~', path: '~')];
  final out = <Crumb>[];
  String acc;
  Iterable<String> rest;
  if (d.startsWith('~/')) {
    acc = '~';
    out.add((label: '~', path: '~'));
    rest = d.substring(2).split('/');
  } else if (d.startsWith('/')) {
    acc = '';
    out.add((label: '/', path: '/'));
    rest = d.substring(1).split('/');
  } else {
    acc = '';
    rest = d.split('/');
  }
  for (final seg in rest.where((s) => s.isNotEmpty)) {
    acc = acc.isEmpty ? (d.startsWith('/') ? '/$seg' : seg) : '$acc/$seg';
    out.add((label: seg, path: acc));
  }
  return out;
}
