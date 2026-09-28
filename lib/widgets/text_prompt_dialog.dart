import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

/// A dialog that asks for one line (or a few) of text. Resolves to what was
/// typed, or null when it was cancelled — by its button, the back gesture or
/// a tap outside.
///
/// The text field's controller belongs to the dialog's own state and goes
/// with it. A controller made by the caller and disposed once the dialog's
/// future resolved was the red screen behind «Назад» on a note: the future
/// resolves as the dialog *starts* to close, and its field is still being
/// drawn through the closing animation, over a controller already gone.
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
  String? hint,
  Widget? header,
  TextInputType? keyboardType,
  TextCapitalization capitalization = TextCapitalization.none,
  int minLines = 1,
  int maxLines = 1,
  bool selectAll = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
      hint: hint,
      header: header,
      keyboardType: keyboardType,
      capitalization: capitalization,
      minLines: minLines,
      maxLines: maxLines,
      selectAll: selectAll,
    ),
  );
}

/// «Перейти к странице»: asks for a page number between 1 and [pageCount],
/// the current one ready to be typed over.
Future<int?> showGoToPageDialog(
  BuildContext context, {
  required int currentPage,
  required int pageCount,
}) async {
  final l10n = AppLocalizations.of(context);
  final text = await showTextPrompt(
    context,
    title: l10n.goToPageTitle,
    confirmLabel: l10n.go,
    initial: '$currentPage',
    hint: l10n.goToPageHint(pageCount),
    keyboardType: TextInputType.number,
    selectAll: true,
  );
  final page = int.tryParse(text?.trim() ?? '');
  if (page == null || page < 1 || page > pageCount) return null;
  return page;
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.hint,
    required this.header,
    required this.keyboardType,
    required this.capitalization,
    required this.minLines,
    required this.maxLines,
    required this.selectAll,
  });

  final String title;
  final String confirmLabel;
  final String initial;
  final String? hint;
  final Widget? header;
  final TextInputType? keyboardType;
  final TextCapitalization capitalization;
  final int minLines;
  final int maxLines;
  final bool selectAll;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void initState() {
    super.initState();
    if (widget.selectAll) {
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initial.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final multiline = widget.maxLines > 1;
    final field = TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: multiline ? TextInputType.multiline : widget.keyboardType,
      textCapitalization: widget.capitalization,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      onSubmitted: multiline ? null : (_) => _submit(),
      decoration: InputDecoration(
        hintText: widget.hint,
        border: multiline ? const OutlineInputBorder() : null,
      ),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: widget.header == null
          ? field
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [widget.header!, const SizedBox(height: 12), field],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
