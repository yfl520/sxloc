import 'package:cupertino_ui/cupertino_ui.dart';

import 'app_updates.dart';

class UpdatePanel extends StatelessWidget {
  const UpdatePanel({super.key, required this.controller});
  final AppUpdateController controller;

  Future<void> _install(BuildContext context) async {
    final android = controller.platform == UpdatePlatform.android;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(android ? '安装更新' : '安装并重新启动'),
        content: Text(
          android
              ? '将打开系统安装界面。安装完成后请重新打开随行定位，当前蓝牙连接会中断。'
              : '更新会关闭随行定位并断开当前设备连接，完成后自动重新打开。设置与收藏保存在本机数据目录，旧版文件夹将保留作为备份。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续安装'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.installDownloaded();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final update = controller.package;
      final stage = controller.stage;
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CupertinoColors.white,
          border: Border.all(color: const Color(0xFFE9EAF0)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '应用更新',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              controller.message,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF71717A),
                height: 1.5,
              ),
            ),
            if (stage == UpdateStage.checking ||
                stage == UpdateStage.installing)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            if (stage == UpdateStage.downloading && update != null) ...[
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => Container(
                  height: 5,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E5EA),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Container(
                    width:
                        constraints.maxWidth *
                        (controller.received / update.size).clamp(0, 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFF007AFF),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(controller.received / update.size * 100).clamp(0, 100).toStringAsFixed(0)}% · '
                '${(controller.received / 1024 / 1024).toStringAsFixed(1)} / '
                '${(update.size / 1024 / 1024).toStringAsFixed(1)} MB',
                style: const TextStyle(fontSize: 12, color: Color(0xFF71717A)),
              ),
            ],
            if (update != null && update.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                '版本说明',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                update.notes,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Color(0xFF71717A),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              children: [
                if (!controller.busy && stage != UpdateStage.ready)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    onPressed: controller.check,
                    child: const Text('检查更新', style: TextStyle(fontSize: 13)),
                  ),
                if (update != null &&
                    !controller.busy &&
                    stage != UpdateStage.ready)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    onPressed: controller.download,
                    child: const Text('下载更新', style: TextStyle(fontSize: 13)),
                  ),
                if (stage == UpdateStage.ready)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    onPressed: () => _install(context),
                    child: Text(
                      controller.platform == UpdatePlatform.android
                          ? '安装更新'
                          : '安装并重启',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                if (stage == UpdateStage.downloading ||
                    stage == UpdateStage.checking)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    onPressed: controller.cancel,
                    child: const Text('取消', style: TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
