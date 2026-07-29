import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  static final _endpoint = Uri.https('talistra.ru', '/api/feedback');

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _contactController = TextEditingController();
  final _messageController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _nameController.dispose();
    _contactController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _sending) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _sending = true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.postUrl(_endpoint);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'name': _nameController.text.trim(),
          'contact': _contactController.text.trim(),
          'message': _messageController.text.trim(),
          'source': 'android',
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var message = l10n.feedbackSendError;
        try {
          final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
          message = decoded['error'] as String? ?? message;
        } on FormatException {
          // A readable fallback is already prepared above.
        }
        throw HttpException(message);
      }
      if (!mounted) return;
      _formKey.currentState!.reset();
      _nameController.clear();
      _contactController.clear();
      _messageController.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.feedbackSent)));
    } on SocketException {
      if (mounted) _showError(l10n.feedbackNoConnection);
    } on HttpException catch (error) {
      if (mounted) _showError(error.message);
    } on Exception {
      if (mounted) _showError(l10n.feedbackSendError);
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.feedbackTitle)),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: colors.primaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.forum_outlined, color: colors.primary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        l10n.feedbackIntro,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              TextFormField(
                controller: _nameController,
                maxLength: 80,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.feedbackNameLabel,
                  hintText: l10n.feedbackOptionalHint,
                  prefixIcon: const Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _contactController,
                maxLength: 160,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.feedbackContactLabel,
                  hintText: l10n.feedbackContactHint,
                  prefixIcon: const Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _messageController,
                minLines: 6,
                maxLines: 12,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.feedbackMessageLabel,
                  alignLabelWithHint: true,
                  hintText: l10n.feedbackMessageHint,
                ),
                validator: (value) => (value?.trim().length ?? 0) < 10
                    ? l10n.feedbackMessageValidation
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                l10n.feedbackPrivacyNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _sending ? null : _submit,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(
                  _sending ? l10n.feedbackSending : l10n.feedbackSend,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
