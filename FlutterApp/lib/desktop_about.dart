import 'package:cupertino_ui/cupertino_ui.dart';

import 'about_page.dart';
import 'app_info.dart';
import 'core_client.dart';
import 'ui.dart';

Future<void> showDesktopAbout(BuildContext context, CoreClient core) =>
    showMacSheet<void>(
      context,
      title: '关于随行定位',
      child: AboutContent(
        version: AppInfo.desktopVersion,
        platform: 'Windows 桌面版',
        onOpenLink: (url) async {
          await core.call('openGithub', {'url': url});
        },
      ),
    );
