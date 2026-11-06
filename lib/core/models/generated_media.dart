/// AI 生成的图片 / 视频，以及用户形象建模。
class GeneratedMedia {
  final String id;
  final String type; // 'image' | 'video'
  final String prompt; // 润色后的提示词
  final String? rawPrompt; // 用户原始提示词
  final String ownerId; // 用户 id
  final String? personaId; // 与某角色合景
  final String filePath; // 本地文件路径
  final int createdAt;

  const GeneratedMedia({
    required this.id,
    required this.type,
    required this.prompt,
    this.rawPrompt,
    required this.ownerId,
    this.personaId,
    required this.filePath,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type,
        'prompt': prompt,
        'raw_prompt': rawPrompt,
        'owner_id': ownerId,
        'persona_id': personaId,
        'file_path': filePath,
        'created_at': createdAt,
      };

  factory GeneratedMedia.fromMap(Map<String, dynamic> m) => GeneratedMedia(
        id: m['id'] as String,
        type: m['type'] as String,
        prompt: m['prompt'] as String,
        rawPrompt: m['raw_prompt'] as String?,
        ownerId: m['owner_id'] as String,
        personaId: m['persona_id'] as String?,
        filePath: m['file_path'] as String,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

/// 用户形象建模（上传图片 → 3D / Q 版建模）。
class UserModel {
  final String id;
  final String userId;
  final String sourceImagePath;
  final String? modelPath; // 生成的 3D / Q 版模型路径
  final int createdAt;

  const UserModel({
    required this.id,
    required this.userId,
    required this.sourceImagePath,
    this.modelPath,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'source_image_path': sourceImagePath,
        'model_path': modelPath,
        'created_at': createdAt,
      };

  factory UserModel.fromMap(Map<String, dynamic> m) => UserModel(
        id: m['id'] as String,
        userId: m['user_id'] as String,
        sourceImagePath: m['source_image_path'] as String,
        modelPath: m['model_path'] as String?,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}
