import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:npl_maintenance/ui/query_sheet.dart';
import 'package:npl_maintenance/ui/work_details.dart';

/// 验证近期新增的本地历史与字段筛选规则，不读取真实本机历史。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('历史只保存最近三十次，完整恢复条件且清空后不再恢复', () async {
    final entries = List.generate(
      35,
      (i) => QueryDraft()
        ..field = 'sysAccept'
        ..value = 'DEMO-$i'
        ..start = DateTime(2026, 1)
        ..end = DateTime(2026, 6)
        ..range = true,
    );
    await saveQueryHistory(entries);
    final saved = await loadQueryHistory();
    expect(saved.length, 30);
    expect(saved.first.value, 'DEMO-0');
    expect(saved.last.value, 'DEMO-29');
    expect(saved.first.toJson(), entries.first.toJson());
    await saveQueryHistory([]);
    expect(await loadQueryHistory(), isEmpty);
  });
  test('非表属性和空普通字段隐藏，全部 EXT 与零值保留', () {
    final fields = woInfoFields({
      'caseNo': 1,
      'phoneNo': '  ',
      'opName': null,
      'extraBean': {'value': 1},
      'signNum': 0,
      'isRead': false,
      'ext2': '',
    });
    expect(fields.containsKey('extraBean'), false);
    expect(fields.containsKey('phoneNo'), false);
    expect(fields.containsKey('opName'), false);
    expect(fields['signNum'], 0);
    expect(fields['isRead'], false);
    for (var n = 1; n <= 10; n++) {
      expect(fields.containsKey('ext$n'), true);
    }
  });
}
