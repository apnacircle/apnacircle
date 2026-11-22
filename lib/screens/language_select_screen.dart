import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';

/// First screen: English or Urdu. Shown once; changeable in Settings.
class LanguageSelectScreen extends StatelessWidget {
  const LanguageSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'ApnaCircle',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose your language / اپنی زبان منتخب کریں',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => context
                    .read<LanguageService>()
                    .choose(const Locale('en')),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('English', style: TextStyle(fontSize: 20)),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => context
                    .read<LanguageService>()
                    .choose(const Locale('ur')),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('اردو', style: TextStyle(fontSize: 20)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
