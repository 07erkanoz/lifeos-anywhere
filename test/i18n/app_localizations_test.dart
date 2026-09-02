import 'package:anyware/i18n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses RTL direction for Arabic only', () {
    expect(AppLocalizations.textDirectionFor('ar'), TextDirection.rtl);
    expect(AppLocalizations.textDirectionFor('tr'), TextDirection.ltr);
    expect(AppLocalizations.textDirectionFor('de'), TextDirection.ltr);
  });
}
