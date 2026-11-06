import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model_service.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/avatar3d/glb_codec.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

void main() {
  final persona = PersonaService.sampleCompanion();
  final spec = PersonaVisualSpec.fromPersona(persona);

  group('Q 版骨骼网格', () {
    test('人设卡生成 22 根骨骼、非空网格，权重与索引合法', () {
      final mesh = buildChibiAvatar(spec);
      expect(mesh.boneCount, AvatarBones.count);
      expect(mesh.boneCount, 22);
      expect(mesh.vertexCount, greaterThan(500));
      expect(mesh.triangleCount, greaterThan(300));
      expect(mesh.indices.length % 3, 0);
      expect(mesh.joints.length, mesh.vertexCount * 4);
      expect(mesh.weights.length, mesh.vertexCount * 4);
      expect(mesh.colors.length, mesh.vertexCount * 4);

      for (final i in mesh.indices) {
        expect(i, inInclusiveRange(0, mesh.vertexCount - 1));
      }
      for (final j in mesh.joints) {
        expect(j, inInclusiveRange(0, mesh.boneCount - 1));
      }
      for (var v = 0; v < mesh.vertexCount; v++) {
        final sum = mesh.weights[v * 4] +
            mesh.weights[v * 4 + 1] +
            mesh.weights[v * 4 + 2] +
            mesh.weights[v * 4 + 3];
        expect(sum, closeTo(1.0, 0.001), reason: '顶点 $v 蒙皮权重未归一化');
      }
      expect(mesh.fingerprint, spec.fingerprint);
      expect(mesh.personaName, spec.name);
      expect(mesh.starMotif, isTrue, reason: '人设喜欢星空 → 星星挂饰应存在');
      expect(mesh.cocoaMotif, isTrue, reason: '人设喜欢热可可 → 杯子应存在');
    });

    test('骨骼层级与逆绑定矩阵正确', () {
      final mesh = buildChibiAvatar(spec);
      mesh.computeBindMatrices();
      expect(mesh.bones.first.parent, -1);
      for (var i = 1; i < mesh.boneCount; i++) {
        expect(mesh.bones[i].parent, lessThan(i));
      }
      // 单位检验：bindGlobal * inverseBind ≈ I
      final prod = mesh.bones[AvatarBones.head].bindGlobal *
          mesh.bones[AvatarBones.head].inverseBind;
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          final expected = r == c ? 1.0 : 0.0;
          expect(prod[c * 4 + r], closeTo(expected, 1e-9));
        }
      }
    });

    test('动画器逐帧产生不同姿态，眨眼由说话风格驱动', () {
      final mesh = buildChibiAvatar(spec);
      mesh.computeBindMatrices();
      final anim = AvatarAnimator(spec, mesh.bones);
      final p0 = anim.pose(0, mood: 'calm').skinMatrices[AvatarBones.head].m[13];
      final p1 = anim.pose(1.2, mood: 'calm').skinMatrices[AvatarBones.head].m[13];
      expect(p0, isNot(closeTo(p1, 1e-6)), reason: '呼吸/侧头应让头部矩阵随时间变化');

      final happy = anim.pose(1.2, mood: 'happy');
      expect(happy.skinMatrices.length, mesh.boneCount);
      expect(anim.localTrs.length, mesh.boneCount);

      // 眨眼周期末尾应把眼睛压扁（scale.y < 1）
      final blinkT = spec.blinkEveryMs / 1000.0 * 0.97;
      final blinked = anim.pose(blinkT, mood: 'calm');
      expect(blinked.skinMatrices[AvatarBones.eyeL].m[5], lessThan(1.0));
    });

    test('SkinPose 蒙皮输出有限且被骨骼真实改变', () {
      final mesh = buildChibiAvatar(spec);
      mesh.computeBindMatrices();
      final anim = AvatarAnimator(spec, mesh.bones);
      final pose = anim.pose(0.7, mood: 'happy', action: 'wave', actionAge: 0.1);
      final outPos = Float32List(mesh.vertexCount * 3);
      final outNrm = Float32List(mesh.vertexCount * 3);
      mesh.skin(pose.skinMatrices, outPos, outNrm);
      for (final x in outPos) {
        expect(x.isFinite, isTrue);
      }
      // 动作应让手臂顶点位置区别于自然待机
      final idle = anim.pose(0.7, mood: 'happy', action: '', actionAge: 99);
      final out2 = Float32List(mesh.vertexCount * 3);
      final nrm2 = Float32List(mesh.vertexCount * 3);
      mesh.skin(idle.skinMatrices, out2, nrm2);
      var diff = 0.0;
      for (var i = 0; i < outPos.length; i++) {
        diff += (outPos[i] - out2[i]).abs();
      }
      expect(diff, greaterThan(0.01), reason: '挥手动作应真实改变蒙皮顶点');
    });
  });

  group('GLB 编解码（标准 glTF 2.0）', () {
    test('导出文件头合法，回读人设指纹 / 网格 / 动画一致', () {
      final mesh = buildChibiAvatar(spec);
      mesh.computeBindMatrices();
      final bytes = encodeGlb(mesh, spec: spec);
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(0, Endian.little), 0x46546C67, reason: 'magic = glTF');
      expect(bd.getUint32(4, Endian.little), 2);
      expect(bd.getUint32(8, Endian.little), bytes.length);

      final back = decodeGlb(bytes);
      expect(back.spec.fingerprint, spec.fingerprint);
      expect(back.spec.name, spec.name);
      expect(back.mesh.vertexCount, mesh.vertexCount);
      expect(back.mesh.boneCount, mesh.boneCount);
      expect(back.animationChannelCount, greaterThan(0));
      back.mesh.computeBindMatrices();
      final anim = AvatarAnimator(back.spec, back.mesh.bones);
      expect(anim.pose(0.3).skinMatrices.length, back.mesh.boneCount);
    });

    test('损坏 / 非 GLB 输入明确报错', () {
      expect(() => decodeGlb(Uint8List(4)), throwsFormatException);
      expect(
        () => decodeGlb(Uint8List.fromList(List.filled(64, 0))),
        throwsFormatException,
      );
    });

    test('换人设生成不同模型，绝不复用别人的形象', () {
      final other = PersonaVisualSpec.fromPersona(
        persona.copyWith(
          name: '另一位角色',
          likes: '园艺、晴天',
          worldSetting: '清新校园日常',
          identity: '图书管理员',
          relationBase: '普通同事',
        ),
      );
      expect(other.fingerprint, isNot(spec.fingerprint));
      final a = buildChibiAvatar(spec);
      final b = buildChibiAvatar(other);
      a.computeBindMatrices();
      b.computeBindMatrices();
      expect(a.starMotif, isTrue);
      expect(b.starMotif, isFalse);
      final ba = encodeGlb(a, spec: spec);
      final bb = encodeGlb(b, spec: other);
      expect(ba.length, isNot(bb.length));
      expect(decodeGlb(bb).spec.fingerprint, other.fingerprint);
    });
  });

  group('App 内生成真实模型文件', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('avatar3d_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('一键生成 → 落盘 .glb → load 可读回 → 文件名绑定指纹', () async {
      final svc = AvatarModelService(baseDirOverride: tmp);
      final result = await svc.generate(spec);
      final file = File(result.filePath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(1000));
      expect(result.bytes, await file.length());
      expect(result.boneCount, 22);
      expect(result.filePath.toLowerCase().endsWith('.glb'), isTrue);

      final loaded = await svc.load(spec);
      expect(loaded, isNotNull);
      expect(loaded!.spec.fingerprint, spec.fingerprint);
      expect(loaded.mesh.vertexCount, result.mesh.vertexCount);
      expect(await svc.listGenerated(), hasLength(1));
    });

    test('人设不匹配时拒绝返回旧模型', () async {
      final svc = AvatarModelService(baseDirOverride: tmp);
      await svc.generate(spec);
      final other = PersonaVisualSpec.fromPersona(
        persona.copyWith(name: '别人', likes: '园艺'),
      );
      expect(await svc.load(other), isNull);
    });

    test('空人设卡生成被拒绝，不产出假文件', () async {
      final svc = AvatarModelService(baseDirOverride: tmp);
      final empty = PersonaVisualSpec.fromMap(const {});
      expect(() => svc.generate(empty), throwsArgumentError);
    });

    test('生成的模型可再次导入，且骨骼数与人设元数据完整', () async {
      final svc = AvatarModelService(baseDirOverride: tmp);
      final made = await svc.generate(spec);
      final imported = await svc.importGlb(made.filePath);
      expect(imported.boneCount, AvatarBones.count);
      expect(imported.spec.fingerprint, spec.fingerprint);
      expect(imported.mesh.vertexCount, made.mesh.vertexCount);
    });

    test('非 GLB / 空文件导入明确报错', () async {
      final svc = AvatarModelService(baseDirOverride: tmp);
      final junk = File('${tmp.path}/junk.glb');
      await junk.writeAsBytes([1, 2, 3, 4]);
      expect(() => svc.importGlb(junk.path), throwsFormatException);
      expect(() => svc.importGlb('${tmp.path}/missing.glb'),
          throwsArgumentError);
    });
  });
}
