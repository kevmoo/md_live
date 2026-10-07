import 'dart:io';

import 'package:md_live/md_live.dart';

Future<void> main(List<String> args) async {
  exitCode = await runMdLiveCli(args);
}
