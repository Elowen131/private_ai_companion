import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';

import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/safety/content_safety_gate.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

/// 人设自检调试页（开发 / 调试用）。
///
/// 用途：在接入真实模型后，快速验证「角色是否守住人设、不 ooc」。
/// 流程：选角色 → 输入测试语 → 跑一次 LLM 回复 → 再用「审查员」模型评估偏离度（1~10 分）。
/// 纯本地、不上报，符合私人本地原则（方案 3.1 / 13 调试工具）。
class PersonaSelfCheckPage extends StatefulWidget {
  const PersonaSelfCheckPage({super.key});

  @override
  State<PersonaSelfCheckPage> createState() => _PersonaSelfCheckPageState();
}

class _PersonaSelfCheckPageState extends State<PersonaSelfCheckPage> {
  final _orchestrator = getIt<ChatOrchestrator>();
  final _llm = getIt<LlmProvider>();
  final _personaService = getIt<PersonaService>();

  List<Persona> _personas = [];
  Persona? _selected;
  final _promptCtl = TextEditingController(text: '今天天气真好，我们一起出去走走吧？');
  bool _running = false;

  String? _reply;
  Map<String, dynamic>? _verdict; // {score, ooc, issues}
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _personaService.list();
    if (mounted) {
      setState(() {
        _personas = list;
        if (list.isNotEmpty) _selected = list.first;
      });
    }
  }

  Future<void> _run() async {
    if (_selected == null || _running) return;

    // 调试页同样经过法律底线闸门，避免成为绕过入口。
    final verdict = getIt<ContentSafetyGate>().check(
      _promptCtl.text,
      involvesMinorPersona: _selected!.isMinor,
    );
    if (verdict.blocked) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(verdict.userMessage)),
        );
      }
      return;
    }

    setState(() {
      _running = true;
      _reply = null;
      _verdict = null;
      _error = null;
    });
    try {
      // 1) 让角色按人设回复测试语
      final ctx = await _orchestrator.buildContext(
        conversationId: 'selfcheck',
        personaId: _selected!.id,
        lastUserText: _promptCtl.text,
      );
      final reply = await _llm.complete(LlmRequest(messages: ctx, maxTokens: 256));

      // 2) 审查员：评估该回复是否偏离人设
      final critic = await _llm.complete(LlmRequest(
        messages: [
          const ChatMessage(
            role: 'system',
            content: '你是「人设一致性审查员」。下面会给你一份角色人设锚点，'
                '以及该角色的一条回复。请判断回复是否偏离人设（OOC）。'
                '只输出 JSON：{"score":1-10 表示贴合度（10=完全贴合）,"ooc":true/false,"issues":"简短说明"}。',
          ),
          ChatMessage(
            role: 'user',
            content: '【人设锚点】\n${_selected!.toPersonaAnchor()}\n\n'
                '【角色回复】\n$reply\n\n请评估。',
          ),
        ],
        temperature: 0.2,
        maxTokens: 200,
      ));

      Map<String, dynamic>? parsed;
      try {
        parsed = _extractJson(critic);
      } catch (_) {
        parsed = null;
      }
      if (mounted) {
        setState(() {
          _reply = reply.trim();
          _verdict = parsed;
          _running = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _running = false;
        });
      }
    }
  }

  /// 从模型输出中尽力提取 JSON（兼容 ```json 包裹）。
  Map<String, dynamic> _extractJson(String text) {
    var t = text.trim();
    final fence = t.indexOf('{');
    final last = t.lastIndexOf('}');
    if (fence >= 0 && last > fence) t = t.substring(fence, last + 1);
    return Map<String, dynamic>.from(jsonDecode(t) as Map);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('人设自检（调试）')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<Persona>(
            initialValue: _selected,
            decoration: const InputDecoration(labelText: '选择角色'),
            items: _personas
                .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                .toList(),
            onChanged: (v) => setState(() => _selected = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptCtl,
            decoration: const InputDecoration(
              labelText: '测试语（模拟用户的一句话）',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running ? '自检中…' : '运行自检'),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Text('错误：$_error', style: const TextStyle(color: Colors.red)),
          if (_reply != null) ...[
            const Text('角色回复', style: TextStyle(fontWeight: FontWeight.bold)),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_reply!),
              ),
            ),
            const SizedBox(height: 12),
            const Text('审查员评估',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _verdict == null
                    ? const Text('（审查员未返回可解析的 JSON，请接入真实模型后重试）')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('贴合度：',
                                  style: theme.textTheme.bodyLarge),
                              Text(
                                '${_verdict!['score'] ?? '-'}/10',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: _isGood(_verdict!['score'])
                                      ? Colors.green
                                      : Colors.orange,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Chip(
                                label: Text(_verdict!['ooc'] == true
                                    ? '疑似 OOC'
                                    : '人设稳定'),
                                backgroundColor: _verdict!['ooc'] == true
                                    ? Colors.orange.withValues(alpha: 0.2)
                                    : Colors.green.withValues(alpha: 0.2),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('说明：${_verdict!['issues'] ?? '（无）'}'),
                        ],
                      ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            '说明：当前默认使用 Mock 模型，回复与评估均为脚本化占位。'
            '接入真实端侧/云端模型后，本页即可用于回归测试「人设是否崩坏」。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  bool _isGood(dynamic score) {
    final v = (score is int ? score : int.tryParse(score.toString())) ?? 0;
    return v >= 7;
  }

  @override
  void dispose() {
    _promptCtl.dispose();
    super.dispose();
  }
}
