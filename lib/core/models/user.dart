/// 本地用户（仅本机）。生日用于法律底线兜底判定（见方案 1.4）。
class AppUser {
  final String id;
  final String nickname;
  final String? avatarPath;
  final String? birthday; // 'YYYY-MM-DD'
  final Map<String, dynamic> globalPrefs; // 全局偏好（含撤回窥视概率等）

  const AppUser({
    required this.id,
    required this.nickname,
    this.avatarPath,
    this.birthday,
    this.globalPrefs = const {},
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'nickname': nickname,
        'avatar_path': avatarPath,
        'birthday': birthday,
        'global_prefs': globalPrefs,
      };

  factory AppUser.fromMap(Map<String, dynamic> m) => AppUser(
        id: m['id'] as String,
        nickname: m['nickname'] as String,
        avatarPath: m['avatar_path'] as String?,
        birthday: m['birthday'] as String?,
        globalPrefs: (m['global_prefs'] as Map? ?? {}).cast<String, dynamic>(),
      );
}
