import 'dart:io';

import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/constants.dart';
import 'package:private_ai_companion/core/models/user.dart';
import 'package:private_ai_companion/data/repositories/user_repository.dart';

/// 个人资料页（用户原始定位：「自定义用户自身头像」）。
/// 昵称 / 头像 / 生日真实写入本地 user 表，路径无效时不保存并给出提示。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _repo = getIt<UserRepository>();
  final _nickname = TextEditingController();
  final _avatar = TextEditingController();
  final _birthday = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await _repo.get(AppConstants.localUserId);
    if (!mounted) return;
    setState(() {
      _nickname.text = u?.nickname ?? '我';
      _avatar.text = u?.avatarPath ?? '';
      _birthday.text = u?.birthday ?? '';
      _loading = false;
    });
  }

  @override
  void dispose() {
    _nickname.dispose();
    _avatar.dispose();
    _birthday.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final path = _avatar.text.trim();
    if (path.isNotEmpty && !File(path).existsSync()) {
      _toast('头像路径下没有找到图片，请检查后重试');
      return;
    }
    final u = AppUser(
      id: AppConstants.localUserId,
      nickname: _nickname.text.trim().isEmpty ? '我' : _nickname.text.trim(),
      avatarPath: path.isEmpty ? null : path,
      birthday: _birthday.text.trim().isEmpty ? null : _birthday.text.trim(),
    );
    await _repo.upsert(u);
    if (!mounted) return;
    _toast('已保存到本机');
    Navigator.of(context).pop();
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('个人资料'),
        actions: [
          TextButton(onPressed: _loading ? null : _save, child: const Text('保存')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _nickname,
                  decoration: const InputDecoration(
                    labelText: '昵称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _avatar,
                  decoration: const InputDecoration(
                    labelText: '我的头像（本机图片路径，可留空）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _birthday,
                  decoration: const InputDecoration(
                    labelText: '生日（YYYY-MM-DD，可留空）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '说明：所有资料仅保存在本机数据库中，不联网、不上报。'
                  '后续版本接入相册选择后可直接点选图片。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
    );
  }
}
