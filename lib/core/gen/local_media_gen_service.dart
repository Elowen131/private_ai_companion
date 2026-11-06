import 'dart:io';
import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/gen/media_gen_service.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/models/generated_media.dart';

/// 本地媒体生成服务。
///
/// **已真实落地**：`polishPrompt` 走本地 LlmProvider（端侧模型优先、Mock 兜底），
/// 把用户的简短提示扩写为完整描述；模型不可用时回退到模板，保证功能不空转。
///
/// **仍为占位管线**：`generateImage` / `generateVideo` 目前返回占位资源路径，
/// 尚需接入端侧扩散模型（见 PRD 9.8）。UI 会明确标注，不把占位结果伪装成已生成媒体。
///
/// **已真实落地**：`buildUserModel` 改为绑定一个确实存在的 3D 模型文件。
/// 过去它无条件返回 `pending_models/<uuid>.vrm` 这条永远不存在的路径，用户点
/// 「生成建模」看到成功提示却拿不到任何模型——现在必须给出真实文件，否则报错。
class LocalMediaGenService implements MediaGenService {
  final LlmProvider? llm;
  final Random _rng = Random();

  LocalMediaGenService({this.llm});

  @override
  Future<String> polishPrompt(String rawPrompt, {String? personaId}) async {
    final model = llm;
    if (model != null && rawPrompt.trim().isNotEmpty) {
      try {
        final out = await model.complete(LlmRequest(
          messages: [
            const ChatMessage(
              role: 'system',
              content: '你是 AI 绘画 / 视频提示词润色助手。把用户简短的想法扩写成一段'
                  '具体、有画面感的中文描述：补充主体、动作、光线、构图与氛围。'
                  '只输出润色后的提示词本身，不要编号、不要解释、不要加引号。',
            ),
            ChatMessage(role: 'user', content: rawPrompt),
          ],
          maxTokens: 200,
          temperature: 0.7,
        ));
        final polished = out.trim();
        if (polished.isNotEmpty) {
          return personaId != null ? '$polished（与角色同框）' : polished;
        }
      } catch (_) {
        // 模型不可用 / 超时 → 回退本地模板，保证流程不中断。
      }
    }
    final extras = [
      '电影感光线，柔焦，细节丰富',
      '暖色黄昏，氛围感，8k',
      '半身构图，眼神温柔，背景虚化',
    ];
    return '$rawPrompt，${extras[_rng.nextInt(extras.length)]}'
        '${personaId != null ? '（与角色同框）' : ''}';
  }

  @override
  Future<UserModel> buildUserModel(
    String userId,
    String sourceImagePath, {
    String? modelFilePath,
  }) async {
    final path = modelFilePath?.trim() ?? '';
    if (path.isEmpty) {
      throw ArgumentError('未提供 3D 模型文件：请先导入 .glb / .obj / .vrm 模型');
    }
    const exts = {'.glb', '.gltf', '.obj', '.vrm', '.fbx', '.stl'};
    final lower = path.toLowerCase();
    if (!exts.any(lower.endsWith)) {
      throw ArgumentError('不支持的模型格式：$path（支持 ${exts.join(' / ')}）');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw ArgumentError('模型文件不存在：$path');
    }
    final size = await file.length();
    if (size <= 0) {
      throw ArgumentError('模型文件为空：$path');
    }
    return UserModel(
      id: const Uuid().v4(),
      userId: userId,
      sourceImagePath: sourceImagePath,
      // 真实存在的文件路径，不再是永远打不开的占位字符串。
      modelPath: file.absolute.path,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<GeneratedMedia> generateImage({
    required String ownerId,
    String? personaId,
    required String rawPrompt,
  }) async {
    final polished = await polishPrompt(rawPrompt, personaId: personaId);
    return GeneratedMedia(
      id: const Uuid().v4(),
      type: 'image',
      prompt: polished,
      rawPrompt: rawPrompt,
      ownerId: ownerId,
      personaId: personaId,
      filePath: 'pending_gen/${const Uuid().v4()}.png',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<GeneratedMedia> generateVideo({
    required String ownerId,
    String? personaId,
    required String rawPrompt,
  }) async {
    final polished = await polishPrompt(rawPrompt, personaId: personaId);
    return GeneratedMedia(
      id: const Uuid().v4(),
      type: 'video',
      prompt: polished,
      rawPrompt: rawPrompt,
      ownerId: ownerId,
      personaId: personaId,
      filePath: 'pending_gen/${const Uuid().v4()}.mp4',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
