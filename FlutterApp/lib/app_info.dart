abstract final class AppInfo {
  static const name = '随行定位';
  static const projectName = name;
  static const desktopVersionName = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.1.4',
  );
  static const desktopBuild = int.fromEnvironment('APP_BUILD', defaultValue: 9);
  static const androidVersionName = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.2.8',
  );
  static const androidBuild = int.fromEnvironment(
    'APP_BUILD',
    defaultValue: 15,
  );
  static const desktopVersion = '$desktopVersionName（$desktopBuild）';
  static const androidVersion = '$androidVersionName（$androidBuild）';
  static const projectGithub = String.fromEnvironment(
    'PROJECT_GITHUB_URL',
    defaultValue: 'https://github.com/yfl520/sxloc',
  );
  static const upstreamGithub = 'https://github.com/D1ngtalk/iap2loc';
  static const identityGithub = 'https://github.com/shihabal3amri/DiPlay';

  static bool isGithubRepository(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        uri.pathSegments.where((s) => s.isNotEmpty).length == 2 &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  static String? get projectRepository =>
      isGithubRepository(projectGithub) ? projectGithub : null;
}
