import 'package:private_ai_companion/core/models/generated_media.dart';

/// AI 图片/视频生成 + 用户形象建模 抽象（方案 4.10）。
///
/// 端侧优先：本地轻量扩散（SD 小量化 / LCM）/ 图生视频；
/// 可选合规云端图像/视频模型作为加速通道。
abstract class MediaGenService {
  /// 提示词润色：把用户简短提示扩写为完整、符合人设与构图的描述。
  Future<String> polishPrompt(String rawPrompt, {String? personaId});

  /// 根据用户上传图片生成用户的 3D / Q 版建模。
  ///
  /// [modelFilePath] 为已经生成/导入的真实 3D 模型文件（.glb/.obj/.vrm 等）。
  /// 端侧「图片→网格」重建管线尚未接入，因此不再返回虚构的占位路径：
  /// 调用方必须给一个确实存在的模型文件，否则直接抛错。
  Future<UserModel> buildUserModel(String userId, String sourceImagePath,
      {String? modelFilePath});

  /// 生成 AI 图片（可指定与某角色合景）。
  Future<GeneratedMedia> generateImage({
    required String ownerId,
    String? personaId, // 合景角色
    required String rawPrompt,
  });

  /// 生成 AI 视频（图生视频 / 姿态驱动）。
  Future<GeneratedMedia> generateVideo({
    required String ownerId,
    String? personaId,
    required String rawPrompt,
  });
}
