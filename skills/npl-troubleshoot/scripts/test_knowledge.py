"""隔离测试经验状态迁移、检索和存储；不写用户真实经验库。"""
import json
from pathlib import Path
import tempfile
import unittest
from knowledge import Library, safe


class KnowledgeTests(unittest.TestCase):
    """用合成案例验证确认边界和反例联动。"""
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.library=Library(self.temp.name)
        self.library.mutate('init',{})

    def make_case(self):
        """创建有检查证据但未经人工确认的案例。"""
        data=dict(title='签字未显示测试',symptom='PDF 签字缺失',environment='合成测试',tags=['签字','PDF'])
        run=self.library.mutate('start',data)
        self.library.mutate('check',dict(step='S1',action='合成只读查询',expected='待确认',observed='合成记录',evidence='测试字段路径',result='待验证',next='人工判断'),run['id'])
        return self.library.mutate('save-case',dict(data,runId=run['id'],hypothesis='合成假设',limitations='仅用于测试'))

    def procedure_input(self, identifier):
        """构造具备三种分支的测试流程。"""
        return dict(caseId=identifier,title='签字场景流程',symptom='PDF 签字缺失',environment='合成测试',tags=['签字'],
                    applicability='测试场景',exclusions='实际业务',conclusionCriteria='人工核对合成证据',
                    steps=[dict(id='S1',action='查看测试字段',expected='测试规则',onPass='结束',onFail='核查',onUnknown='补充证据')])

    def test_lifecycle_and_counterexample(self):
        case=self.make_case()
        self.assertEqual(case['status'],'待确认')
        with self.assertRaises(ValueError):
            self.library.mutate('promote',self.procedure_input(case['id']))
        with self.assertRaises(ValueError):
            self.library.mutate('confirm',{},case['id'])
        self.library.mutate('confirm',{},case['id'],'测试用户','测试确认原话')
        procedure=self.library.mutate('promote',self.procedure_input(case['id']))
        self.assertEqual(procedure['status'],'待确认')
        self.library.mutate('confirm',{},procedure['id'],'测试用户','测试流程确认')
        self.library.mutate('flag',{'reason':'合成反例'},case['id'])
        self.assertEqual(self.library.get(procedure['id'])['status'],'待复核')
        with self.assertRaises(ValueError):
            self.library.mutate('confirm',{},procedure['id'],'测试用户','不应通过')

    def test_search_and_revision(self):
        case=self.make_case()
        found=self.library.search('签字没有显示')
        self.assertEqual(found[0]['id'],case['id'])
        self.assertEqual(found[0]['status'],'待确认')
        revised=self.library.mutate('revise',{'reason':'测试修订','changes':{'hypothesis':'新假设'}},case['id'])
        self.assertEqual(revised['history'][-2]['previous']['hypothesis'],'合成假设')
        self.assertTrue(self.library.path(case['id']).with_suffix('.md').exists())
        self.assertEqual(len(json.loads((Path(self.temp.name)/'index.json').read_text())),2)

    def test_invalid_record_and_credential(self):
        with self.assertRaises(ValueError):
            self.library.get('../../auth.json')
        for value in [{'storePassword':'秘密'},{'acceptContent':'未屏蔽正文'},{'text':'-----BEGIN PRIVATE KEY-----'}]:
            with self.assertRaises(ValueError):
                safe(value)
        safe({'acceptContent':'[已屏蔽]'})

    def test_bad_procedure_revision_preserves_record(self):
        case=self.make_case()
        self.library.mutate('confirm',{},case['id'],'测试用户','确认')
        procedure=self.library.mutate('promote',self.procedure_input(case['id']))
        with self.assertRaises(ValueError):
            self.library.mutate('revise',{'reason':'错误输入','changes':{'steps':[]}},procedure['id'])
        self.assertEqual(len(self.library.get(procedure['id'])['steps']),1)

    def test_empty_library(self):
        self.assertEqual(self.library.search('任意场景'),[])
        self.assertEqual(self.library.records(),[])


if __name__=='__main__':
    unittest.main()
