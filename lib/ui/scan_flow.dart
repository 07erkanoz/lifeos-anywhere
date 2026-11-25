import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:anyware/core/open_any_file.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/scan/document_scan.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/ui/devices_home.dart';
import 'package:anyware/ui/ui_strings.dart';

/// Belge tara: camera to PDF, saved in the download folder. With [toDevice]
/// it goes straight into that conversation; otherwise a snack bar offers to
/// open it or send it to anyone (this network or far away).
Future<void> scanToPdfFlow(BuildContext context, WidgetRef ref, {String? toDevice}) async {
  final locale = ref.read(settingsProvider).locale;
  final messenger = ScaffoldMessenger.of(context);
  final String? path;
  try {
    path = await DocumentScan.toPdf(ref.read(settingsProvider).downloadPath);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(S.get('scanUnavailable', locale))));
    return;
  }
  if (path == null) return;
  if (toDevice != null) {
    await ref.read(iletiProvider.notifier).sendFiles(toDevice, [path]);
    return;
  }
  final name = path.split(RegExp(r'[/\\]')).last;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: GestureDetector(
        onTap: () => openAnyFile(path!),
        child: Text(S.get('scanSaved', locale, {'name': name})),
      ),
      action: SnackBarAction(
        label: S.get('scanShare', locale),
        onPressed: () {
          if (context.mounted) sendFilesFlow(context, ref, paths: [path!]);
        },
      ),
    ));
}

/// A photo taken with the camera now, into [device]'s conversation.
Future<void> cameraPhotoFlow(WidgetRef ref, String device) async {
  final shot = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 88);
  if (shot == null) return;
  await ref.read(iletiProvider.notifier).sendFiles(device, [shot.path]);
}
