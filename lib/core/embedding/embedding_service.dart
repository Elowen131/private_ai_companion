import 'dart:math';

/// 向量化抽象（用于记忆语义检索 / RAG）。
/// 端侧优先：本地 embedding 模型（如 bge-small / nomic 量化）。
abstract class EmbeddingService {
  /// 返回固定维度向量（如 384 / 768）。
  Future<List<double>> embed(String text);

  /// 向量维度（全库一致，更换模型需重建向量表，见方案 3.3）。
  int get dimension;
}

/// 默认 Mock：产生确定性伪向量，便于在无模型时跑通检索链路。
class MockEmbeddingService implements EmbeddingService {
  @override
  final int dimension = 64;

  @override
  Future<List<double>> embed(String text) async {
    final out = List<double>.filled(dimension, 0.0);
    var h = 2166136261;
    for (var i = 0; i < text.length; i++) {
      h ^= text.codeUnitAt(i);
      h = h * 16777619 & 0x7fffffff;
      out[i % dimension] += (h % 100) / 100.0;
    }
    // 归一化
    final norm = out.map((e) => e * e).reduce((a, b) => a + b);
    final n = norm > 0 ? sqrt(norm) : 1.0;
    return out.map((e) => e / n).toList();
  }
}
