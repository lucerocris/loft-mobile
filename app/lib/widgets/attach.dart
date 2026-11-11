import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/loft_client.dart';
import '../screens/group_sheet.dart';
import 'common.dart';

/// Pick photos or files on the phone, upload them to the laptop and append
/// their laptop paths to [field], so the prompt points the agent at them.
/// Returns false when nothing was attached.
Future<bool> attachFiles(BuildContext context, LoftClient client, TextEditingController field) async {
  final type = await showPickerSheet<FileType>(
    context,
    (ctx) => [
      const SheetTitle('Attach', subtitle: 'Sent to the laptop; the agent gets the path'),
      OptionRow(lead: const Icon(LucideIcons.image, size: 20), title: 'Photos', onTap: () => Navigator.pop(ctx, FileType.media)),
      OptionRow(lead: const Icon(LucideIcons.folder, size: 20), title: 'Files', onTap: () => Navigator.pop(ctx, FileType.any)),
    ],
  );
  if (type == null) return false;
  // compatible: iPhone photos arrive as JPEG, not HEIC, which agents can't read.
  final files = await FilePicker.pickFiles(type: type, darwinOptions: const DarwinOptions(assetRepresentationMode: DarwinAssetRepresentationMode.compatible));
  if (files.isEmpty || !context.mounted) return false;
  toast(context, files.length == 1 ? 'Sending ${files.single.name}…' : 'Sending ${files.length} files…', duration: const Duration(minutes: 2));
  final paths = <String>[];
  try {
    for (final f in files) {
      paths.add(await client.upload(f.name, await f.readAsBytes()));
    }
  } on LoftError catch (e) {
    if (context.mounted) toast(context, e.message, error: true);
  }
  if (paths.isEmpty) return false;
  final t = field.text.trimRight();
  field.text = '${t.isEmpty ? '' : '$t\n'}${paths.join('\n')}\n';
  field.selection = TextSelection.collapsed(offset: field.text.length);
  if (context.mounted && paths.length == files.length) toast(context, paths.length == 1 ? 'Attached' : 'Attached ${paths.length} files');
  return true;
}
