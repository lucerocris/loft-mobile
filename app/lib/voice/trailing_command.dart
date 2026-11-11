/// Hands-free submit, same rule as desktop Loft's deliver():
/// /[,.]?\s*(start it|send it|go ahead and send( it)?)[.!]?$/i
library;

final trailingGo = RegExp(r'[,.]?\s*(start it|send it|go ahead and send( it)?)[.!]?$', caseSensitive: false);

class Trailing {
  final String text; // transcript without the phrase
  final bool go; // the phrase was there: submit after the Undo window
  const Trailing(this.text, this.go);
}

Trailing parseTrailing(String transcript) {
  final t = transcript.trim();
  if (!trailingGo.hasMatch(t)) return Trailing(t, false);
  return Trailing(t.replaceFirst(trailingGo, '').trim(), true);
}

/// Splits a live partial into the part that has settled (same words as the
/// previous partial) and the tail that may still change, which the UI greys out.
({String stable, String tail}) splitPartial(String previous, String current) {
  final a = previous.trim().split(RegExp(r'\s+')), b = current.trim().split(RegExp(r'\s+'));
  var i = 0;
  while (i < a.length && i < b.length && a[i].toLowerCase() == b[i].toLowerCase()) {
    i++;
  }
  // Always keep the last couple of words provisional while listening.
  final keep = i.clamp(0, (b.length - 2).clamp(0, b.length));
  final stable = b.take(keep).join(' ');
  final tail = b.skip(keep).join(' ');
  return (stable: stable, tail: tail);
}
