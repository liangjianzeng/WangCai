// 热词词表扩容 + 分类差量编辑回归：effectiveCategoryWords /
// diffCategoryWords 纯函数（设置页词表编辑 → 持久化 → loadHotwords 合并）。
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/asr/default_hotwords.dart';

void main() {
  test('默认分类覆盖既有 5 类 + 新增 4 类（应用/手机操作/生活/办公）', () {
    final ids = hotwordCategories.map((c) => c.id).toSet();
    expect(
        ids,
        containsAll(
            ['agent', 'edge', 'app', 'dev', 'daily', 'apps', 'phoneops', 'life', 'office']));
    // 新分类各有实际词量（防止将来被清空成摆设）。
    for (final id in ['apps', 'phoneops', 'life', 'office']) {
      expect(defaultCategoryWords(id).length, greaterThanOrEqualTo(20),
          reason: '$id 分类词量不足');
    }
  });

  test('新增四个分类的默认热词均为非空纯中文词（混合英文词在分流时会被整体丢弃）', () {
    // 历史分类（app 的「彤 Yi」等混排词）不在断言范围；新分类必须纯中文。
    for (final id in ['apps', 'phoneops', 'life', 'office']) {
      final cat = hotwordCategories.firstWhere((c) => c.id == id);
      for (final w in cat.words) {
        expect(w.trim(), isNotEmpty, reason: '${cat.id} 有空词');
        expect(w, matches(RegExp(r'^[\u3400-\u9fff\uf900-\ufaff]+$')),
            reason: '${cat.id} 分类存在非纯中文词：$w（解码器/同音校正两路都不生效）');
      }
    }
  });

  test('effectiveCategoryWords = 默认 + 增 − 删', () {
    final added = {
      'daily': ['新词甲', '新词乙']
    };
    final removed = {
      'daily': ['确认']
    };
    final eff = effectiveCategoryWords('daily', added, removed);
    expect(eff, containsAll(['新词甲', '新词乙', '你好']));
    expect(eff, isNot(contains('确认')));
  });

  test('差量存储不随默认表改版丢失：未动的默认词始终生效', () {
    final removed = {'daily': ['你好']};
    final eff = effectiveCategoryWords('daily', const {}, removed);
    expect(eff, isNot(contains('你好')));
    expect(eff, contains('谢谢')); // 其余默认词不受影响
  });

  test('diffCategoryWords：增删差量往返', () {
    final defaults = defaultCategoryWords('daily').toSet();
    final edited = [...defaults.where((w) => w != '你好'), '自造词甲']..shuffle();
    final d = diffCategoryWords('daily', edited);
    expect(d.added, ['自造词甲']);
    expect(d.removed, ['你好']);

    // 保存后再取生效词表 = 编辑后的表（幂等）。
    final eff = effectiveCategoryWords('daily',
        {'daily': d.added}, {'daily': d.removed});
    expect(eff.toSet(), edited.toSet());
  });

  test('diffCategoryWords：与默认一致时差量为空（清除覆盖恢复内置）', () {
    final d = diffCategoryWords('daily', defaultCategoryWords('daily'));
    expect(d.added, isEmpty);
    expect(d.removed, isEmpty);
  });

  test('diffCategoryWords 忽略空行与首尾空白并去重', () {
    // 新表 = 全部默认词 + 带空白/重复的新词 → 只有「新词」入差量，默认词零删。
    final d = diffCategoryWords(
        'daily', [...defaultCategoryWords('daily'), '', '  ', ' 新词 ', '新词']);
    expect(d.added, ['新词']);
    expect(d.removed, isEmpty);
  });
}
