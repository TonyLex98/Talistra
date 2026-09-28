import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/app_reloader.dart';
import '../services/backup.dart';
import '../services/library_service.dart';

/// Settings' «Резервная копия»: save everything the reader has made in the
/// app to a file, or bring it back from one.
class BackupSection extends StatefulWidget {
  const BackupSection({super.key});

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  bool _busy = false;

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // The page just turned is still waiting for its coalesced write.
    context.read<LibraryService>().saveNow();
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final day =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final path = await FilePicker.saveFile(
        fileName: 'talistra_backup_$day.json',
        bytes: Uint8List.fromList(utf8.encode(createBackup(prefs, now: now))),
      );
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.backupSaved)));
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.backupFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final reloader = context.read<AppReloader>();
    context.read<LibraryService>().saveNow();
    final picked = await FilePicker.pickFiles(withData: true);
    final file = picked?.files.singleOrNull;
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) throw const FormatException('Empty file');
      final prefs = await SharedPreferences.getInstance();
      await restoreBackup(prefs, utf8.decode(bytes, allowMalformed: true));
      await reloader.reload();
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupRestored)));
    } catch (error) {
      final reason = error is FormatException ? error.message : '$error';
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.backupFailed(reason))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: const Icon(Icons.save_alt),
          title: Text(l10n.backupExport),
          subtitle: Text(l10n.backupExportSubtitle),
          enabled: !_busy,
          onTap: _export,
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: const Icon(Icons.settings_backup_restore),
          title: Text(l10n.backupImport),
          subtitle: Text(l10n.backupImportSubtitle),
          enabled: !_busy,
          onTap: _import,
        ),
      ],
    );
  }
}
