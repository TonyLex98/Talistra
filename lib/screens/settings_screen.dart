import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/app_language.dart';
import '../services/model_download_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/reading_text_style.dart';
import '../widgets/language_picker_sheet.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsScreenTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // The interface language comes first and shows flags: someone who
          // opens the app and can't read a word of the current language has
          // to be able to find this without understanding the labels.
          const _AppLanguageSection(),
          const Divider(height: 32),
          _SectionHeader(l10n.translatorSectionTitle),
          _TranslatorToggleTile(),
          if (settings.translatorEnabled) ...[
            const _LanguageSection(),
          ] else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                l10n.translatorDisabledNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const Divider(height: 32),
          _SectionHeader(l10n.sectionAppearance),
          const _ReadingThemeSection(),
          const SizedBox(height: 20),
          _SectionHeader(l10n.readingDisplaySection),
          const _ReadingDisplaySection(),
          const SizedBox(height: 20),
          _SectionHeader(l10n.readingTypographySection),
          const _ReadingTypographySection(),
          if (settings.translatorEnabled) ...[
            const Divider(height: 32),
            _SectionHeader(l10n.syncTranslationSectionTitle),
            const _SyncTranslationSection(),
          ],
          const Divider(height: 32),
          _SectionHeader(l10n.sectionAbout),
          const _AboutSection(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TranslatorToggleTile extends StatelessWidget {
  const _TranslatorToggleTile();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      secondary: const Icon(Icons.translate),
      title: Text(AppLocalizations.of(context).translatorSectionTitle),
      value: settings.translatorEnabled,
      onChanged: settings.setTranslatorEnabled,
    );
  }
}

class _LanguageSection extends StatelessWidget {
  const _LanguageSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final translation = context.read<TranslationService>();

    return Column(
      children: [
        ListTile(
          leading: Text(
            settings.sourceAppLanguage.flag,
            style: const TextStyle(fontSize: 22),
          ),
          title: Text(l10n.originalLanguage),
          subtitle: Text(settings.sourceAppLanguage.displayName),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showLanguagePicker(
              context: context,
              current: settings.sourceLanguage,
              title: l10n.fromLanguagePickerTitle,
            );
            if (picked != null) settings.setSourceLanguage(picked);
          },
        ),
        Center(
          child: IconButton.filledTonal(
            icon: const Icon(Icons.swap_vert),
            tooltip: l10n.swapLanguagesTooltip,
            onPressed: settings.swapLanguages,
          ),
        ),
        ListTile(
          leading: Text(
            settings.targetAppLanguage.flag,
            style: const TextStyle(fontSize: 22),
          ),
          title: Text(l10n.translationLanguage),
          subtitle: Text(settings.targetAppLanguage.displayName),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showLanguagePicker(
              context: context,
              current: settings.targetLanguage,
              title: l10n.toLanguagePickerTitle,
            );
            if (picked != null) settings.setTargetLanguage(picked);
          },
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            l10n.translationOfflineNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
        _ModelStatusTile(
          language: settings.sourceLanguage,
          appLanguage: settings.sourceAppLanguage,
          translation: translation,
        ),
        _ModelStatusTile(
          language: settings.targetLanguage,
          appLanguage: settings.targetAppLanguage,
          translation: translation,
        ),
      ],
    );
  }
}

class _ModelStatusTile extends StatefulWidget {
  const _ModelStatusTile({
    required this.language,
    required this.appLanguage,
    required this.translation,
  });

  final TranslateLanguage language;
  final AppLanguage appLanguage;
  final TranslationService translation;

  @override
  State<_ModelStatusTile> createState() => _ModelStatusTileState();
}

class _ModelStatusTileState extends State<_ModelStatusTile> {
  bool? _downloaded;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _ModelStatusTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language) _refresh();
  }

  Future<void> _refresh() async {
    final downloaded = await widget.translation.isModelDownloaded(
      widget.language,
    );
    if (mounted) setState(() => _downloaded = downloaded);
  }

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      await widget.translation.deleteModel(widget.language);
      await _refresh();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final downloadService = context.watch<ModelDownloadService>();
    final isDownloadingThis = downloadService.isDownloadingLanguage(
      widget.language,
    );

    String subtitle;
    if (isDownloadingThis) {
      subtitle = l10n.downloadingProgress(downloadService.elapsedSeconds);
    } else if (_downloaded == null) {
      subtitle = l10n.checkingModel;
    } else {
      subtitle = _downloaded! ? l10n.modelDownloaded : l10n.modelNotDownloaded;
    }

    Widget trailing;
    if (isDownloadingThis || _deleting) {
      trailing = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      trailing = TextButton(
        onPressed: _downloaded == null || downloadService.isDownloading
            ? null
            : (_downloaded == true
                  ? _delete
                  : () => downloadService
                        .download(widget.language)
                        .then((_) => _refresh())),
        child: Text(_downloaded == true ? l10n.delete : l10n.download),
      );
    }

    return ListTile(
      dense: true,
      leading: const SizedBox(width: 22),
      title: Text(l10n.modelLabel(widget.appLanguage.displayName)),
      subtitle: Text(subtitle),
      trailing: trailing,
    );
  }
}

class _ReadingThemeSection extends StatelessWidget {
  const _ReadingThemeSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.readingThemeBackground,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          // Swatches rather than a row of words: the whole point of the
          // setting is what the page will look like, so each option shows
          // its own paper and ink.
          LayoutBuilder(
            builder: (context, constraints) {
              // Three across, as many rows as it takes — six papers don't
              // fit in one row on a phone.
              const spacing = 10.0;
              final width = (constraints.maxWidth - spacing * 2) / 3;
              return Wrap(
                spacing: spacing,
                runSpacing: 12,
                children: [
                  for (final theme in ReadingTheme.values)
                    SizedBox(
                      width: width,
                      child: _ReadingThemeSwatch(
                        theme: theme,
                        label: theme.label(l10n),
                        selected: settings.readingTheme == theme,
                        onTap: () => settings.setReadingTheme(theme),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ReadingDisplaySection extends StatelessWidget {
  const _ReadingDisplaySection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final brightness = settings.readingBrightness;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.brightness_6_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.readingBrightnessLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                brightness == null
                    ? l10n.readingBrightnessSystemValue
                    : '${(brightness * 100).round()}%',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.readingBrightnessSystem),
            value: brightness == null,
            onChanged: (useSystem) =>
                settings.setReadingBrightness(useSystem ? null : 0.65),
          ),
          Slider(
            value: brightness ?? 0.65,
            min: 0.05,
            max: 1,
            divisions: 19,
            label: '${((brightness ?? 0.65) * 100).round()}%',
            onChanged: brightness == null
                ? null
                : settings.setReadingBrightness,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.screen_lock_portrait_outlined),
            title: Text(l10n.keepScreenOnTitle),
            subtitle: Text(l10n.keepScreenOnSubtitle),
            value: settings.keepScreenOnWhileReading,
            onChanged: settings.setKeepScreenOnWhileReading,
          ),
          if (settings.keepScreenOnWhileReading) ...[
            const SizedBox(height: 4),
            Text(
              l10n.keepScreenOnBatteryLabel(settings.keepScreenOnAboveBattery),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Slider(
              value: settings.keepScreenOnAboveBattery.toDouble(),
              min: 1,
              max: 100,
              divisions: 99,
              label: '${settings.keepScreenOnAboveBattery}%',
              onChanged: (value) =>
                  settings.setKeepScreenOnAboveBattery(value.round()),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppLanguageSection extends StatelessWidget {
  const _AppLanguageSection();

  static const _languages = [
    (locale: Locale('ru'), flag: '🇷🇺', name: 'Русский'),
    (locale: Locale('en'), flag: '🇬🇧', name: 'English'),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.language, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                l10n.appLanguageSection,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final language in _languages) ...[
                Expanded(
                  child: _LanguageButton(
                    flag: language.flag,
                    name: language.name,
                    selected:
                        settings.appLocale.languageCode ==
                        language.locale.languageCode,
                    onTap: () => settings.setAppLocale(language.locale),
                  ),
                ),
                if (language != _languages.last) const SizedBox(width: 10),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const _LanguageButton({
    required this.flag,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String flag;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(flag, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 18, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _SyncTranslationSection extends StatelessWidget {
  const _SyncTranslationSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            l10n.syncTranslationDescription,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          secondary: const Icon(Icons.splitscreen),
          title: Text(l10n.syncTranslationTooltip),
          value: settings.syncTranslationExperimental,
          onChanged: settings.setSyncTranslationExperimental,
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Text(AppLocalizations.of(context).aboutText),
    );
  }
}

/// Font, weight and contrast for reading text — with a live sample above
/// the controls, because none of these three settings means anything to a
/// reader as a word: they have to see the actual page.
class _ReadingTypographySection extends StatelessWidget {
  const _ReadingTypographySection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadingPreview(settings: settings),
          const SizedBox(height: 16),
          Text(l10n.readingFontLabel, style: _labelStyle(context)),
          const SizedBox(height: 8),
          // Each choice is shown *in its own typeface*, so the list itself
          // is the specimen sheet.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final font in ReadingFont.values)
                ChoiceChip(
                  selected: settings.readingFont == font,
                  onSelected: (_) => settings.setReadingFont(font),
                  label: Text(
                    font.label,
                    style: TextStyle(fontFamily: font.family, fontSize: 15),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(l10n.readingWeightLabel, style: _labelStyle(context)),
          Slider(
            value: settings.readingWeight.toDouble(),
            min: 300,
            max: 800,
            // 50-unit steps: the bundled families are variable fonts, so
            // any weight in between is a real weight, not a synthetic one.
            divisions: 10,
            label: '${settings.readingWeight}',
            onChanged: (value) => settings.setReadingWeight(value.round()),
          ),
          Text(l10n.readingContrastLabel, style: _labelStyle(context)),
          Slider(
            value: settings.readingContrast,
            divisions: 10,
            label: '${(settings.readingContrast * 100).round()}%',
            onChanged: settings.setReadingContrast,
          ),
          Text(
            l10n.readingTypographyNote,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  TextStyle? _labelStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyMedium
      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
}

/// The sample page: real reading colours, real reading typeface, at the
/// real weight and contrast — the same [readingTextStyle] the reader uses.
class _ReadingPreview extends StatelessWidget {
  const _ReadingPreview({required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = settings.readingTheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        color: theme.background,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.readingPreviewTitle,
              style: readingTextStyle(
                settings: settings,
                fontSize: 15,
                sizeFactor: 1.1,
                heightFactor: 0.85,
                bold: true,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.readingPreviewText,
              style: readingTextStyle(settings: settings, fontSize: 16),
            ),
            const SizedBox(height: 10),
            // The marker highlight, so the reading colours are all visible
            // in one place.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: theme.wordHighlight,
              child: Text(
                l10n.selectionCopy,
                style: readingTextStyle(
                  settings: settings,
                  fontSize: 14,
                ).copyWith(color: const Color(0xFF1A1A1A)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One reading-background option, drawn as a small page: its paper colour,
/// its ink colour, and its highlight.
class _ReadingThemeSwatch extends StatelessWidget {
  const _ReadingThemeSwatch({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ReadingTheme theme;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Container(
            height: 62,
            decoration: BoxDecoration(
              color: theme.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2.5 : 1,
              ),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Aa',
                  style: TextStyle(
                    color: theme.onBackground,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Container(width: 26, height: 5, color: theme.wordHighlight),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
