#!/usr/bin/env python3
"""NPL 故障经验库：结构化记录为事实源，Markdown 和索引可重建。"""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import uuid

KINDS = {'run': 'runs', 'case': 'cases', 'procedure': 'procedures'}
FORBIDDEN = {'password', 'storepassword', 'keypassword', 'privatekey', 'token', 'jwt', 'kka', 'kkk', 'agauthorization', 'authorization'}


def now():
    """以带时区的时间保存可追溯记录。"""
    return datetime.datetime.now().astimezone().isoformat(timespec='seconds')


def require(condition, message):
    """校验失败时只返回固定说明，不回显输入。"""
    if not condition:
        raise ValueError(message)


def safe(value):
    """经验仅存必要证据；拒绝明显凭据、原始响应和未屏蔽受理正文。"""
    if isinstance(value, dict):
        for key, item in value.items():
            require(key.lower() not in FORBIDDEN, '经验库禁止保存认证字段')
            require(key not in ('rawResponse', 'rawBody'), '请引用经过 npl-api 处理的响应文件，不保存原始响应')
            if key == 'acceptContent':
                require(item == '[已屏蔽]', 'acceptContent 必须已屏蔽')
            safe(item)
    elif isinstance(value, list):
        for item in value:
            safe(item)
    elif isinstance(value, str):
        require('PRIVATE KEY-----' not in value and not re.search(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', value), '禁止保存私钥或 JWT')
        require(len(value) <= 12000, '单个经验字段超过一万二千字符，请提取证据并引用文件')


def read_input(path):
    """读取人工或智能体准备的结构化说明，不执行其中任何命令。"""
    value = json.loads(Path(path).read_text(encoding='utf-8'))
    require(isinstance(value, dict), '输入必须是 JSON 对象')
    safe(value)
    return value


def text(value, key):
    """获取非空说明字段。"""
    require(isinstance(value.get(key), str) and value[key].strip(), f'缺少非空文本字段：{key}')
    return value[key].strip()


def atomic(path, content):
    """同目录临时文件替换，防止写入中断破坏已保存记录。"""
    fd, temporary = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Library:
    """以 JSON 保存版本和状态，生成可阅读 Markdown；索引不代替记录。"""
    def __init__(self, root):
        self.root = Path(root).expanduser().resolve()

    @contextlib.contextmanager
    def lock(self):
        """所有写操作加进程锁，避免并发排查覆盖步骤。"""
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        for folder in KINDS.values():
            (self.root/folder).mkdir(exist_ok=True, mode=0o700)
        with (self.root/'.lock').open('a') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(stream, fcntl.LOCK_UN)

    def path(self, identifier):
        """限定 ID 格式，禁止通过相对路径读取其他配置。"""
        require(bool(re.fullmatch(r'(run|case|procedure)-[0-9a-f]{12}', identifier)), '记录 ID 格式无效')
        return self.root/KINDS[identifier.split('-')[0]]/(identifier+'.json')

    def get(self, identifier):
        """按 ID 读取记录；只读取固定经验目录中的 JSON。"""
        return json.loads(self.path(identifier).read_text(encoding='utf-8'))

    def records(self):
        """从事实源列举记录，避免索引中断导致检索遗漏。"""
        return [json.loads(p.read_text(encoding='utf-8')) for folder in KINDS.values()
                for p in sorted((self.root/folder).glob('*.json'))]

    def save(self, record):
        """写入事实源后生成中文阅读副本及轻量索引。"""
        safe(record)
        for key in ['title','symptom','environment']:
            text(record,key)
        require(isinstance(record.get('tags'),list) and all(isinstance(tag,str) for tag in record['tags']), '标签必须为文本数组')
        if record['kind']=='procedure':
            for key in ['applicability','exclusions','conclusionCriteria']:
                text(record,key)
            steps=record.get('steps')
            require(isinstance(steps,list) and bool(steps),'流程步骤不能为空')
            for step in steps:
                require(isinstance(step,dict),'流程步骤必须是对象')
                for key in ['id','action','expected','onPass','onFail','onUnknown']:
                    text(step,key)
            require(len({step['id'] for step in steps})==len(steps),'流程步骤 ID 不可重复')
        if record['kind']=='case':
            for key in ['hypothesis','limitations']:
                text(record,key)
        record['updatedAt'] = now()
        path = self.path(record['id'])
        atomic(path, json.dumps(record, ensure_ascii=False, indent=2)+'\n')
        markdown = f"# {record['title']}\n\n状态：{record['status']}\n\n"
        markdown += '以下结构化内容为完整记录；修改请通过脚本执行，保留变更历史。\n\n```json\n'
        markdown += json.dumps(record, ensure_ascii=False, indent=2)+'\n```\n'
        atomic(path.with_suffix('.md'), markdown)
        self.reindex()
        return record

    def reindex(self):
        """仅索引标题、症状、标签和状态，不把响应全文送入检索结果。"""
        entries = [{key:r.get(key) for key in ['id','kind','title','symptom','tags','status','environment','updatedAt']}
                   for r in self.records()]
        atomic(self.root/'index.json', json.dumps(entries, ensure_ascii=False, indent=2)+'\n')
        return len(entries)

    def create(self, kind, value):
        """生成不可猜测的 ID，不允许输入覆盖确认状态或追溯信息。"""
        return dict(id=kind+'-'+uuid.uuid4().hex[:12], kind=kind, title=text(value,'title'),
                    symptom=text(value,'symptom'), environment=text(value,'environment'),
                    tags=value.get('tags',[]), createdAt=now(), history=[])

    def mutate(self, command, value, identifier=None, confirmer=None, confirmation=None):
        """执行限定的经验状态迁移，不调用业务接口或执行流程中的文本。"""
        with self.lock():
            if command=='init':
                return {'records':self.reindex(), 'directory':str(self.root)}
            if command=='start':
                r=self.create('run',value)
                r.update(status='进行中', checks=[], sources=value.get('sources',[]))
            elif command=='check':
                r=self.get(identifier)
                require(r['kind']=='run' and r['status']=='进行中','只能给进行中的排查追加步骤')
                step={key:text(value,key) for key in ['step','action','expected','observed','evidence','next']}
                require(value.get('result') in ['通过','异常','待验证','不适用'],'步骤结果必须为通过、异常、待验证或不适用')
                step.update(result=value['result'], time=now())
                r['checks'].append(step)
            elif command=='save-case':
                run=self.get(text(value,'runId'))
                require(run['kind']=='run' and run['checks'],'案例必须来源于已有检查记录')
                r=self.create('case',value)
                r.update(status='待确认', runId=run['id'], checks=run['checks'],
                         hypothesis=text(value,'hypothesis'), resolution=value.get('resolution','尚未验证'),
                         limitations=text(value,'limitations'))
            elif command=='confirm':
                r=self.get(identifier)
                require(r['kind'] in ['case','procedure'] and r['status'] in ['待确认','待复核'],'该记录不能直接确认')
                require(bool(confirmer and confirmation),'确认需要确认人及用户确认原话')
                if r['kind']=='procedure':
                    require(all(self.get(case_id)['status']=='已确认' for case_id in r['caseIds']), '来源案例尚未确认，不能确认流程')
                r.update(status='已确认', confirmedBy=confirmer, confirmation=confirmation, confirmedAt=now())
            elif command=='promote':
                case=self.get(text(value,'caseId'))
                require(case['kind']=='case' and case['status']=='已确认','只能从人工已确认案例提炼流程')
                steps=value.get('steps')
                require(isinstance(steps,list) and bool(steps),'排查流程至少需要一个步骤')
                for step in steps:
                    require(isinstance(step,dict),'流程步骤必须是对象')
                    for key in ['id','action','expected','onPass','onFail','onUnknown']:
                        text(step,key)
                ids=[s['id'] for s in steps]
                require(len(ids)==len(set(ids)), '流程步骤 ID 不可重复')
                r=self.create('procedure',value)
                r.update(status='待确认', caseIds=[case['id']], applicability=text(value,'applicability'),
                         exclusions=text(value,'exclusions'), conclusionCriteria=text(value,'conclusionCriteria'),
                         steps=steps, version=1)
            elif command=='flag':
                r=self.get(identifier)
                require(r['kind'] in ['case','procedure'],'仅案例或流程可标记反例')
                reason=text(value,'reason')
                r['status']='待复核'
                r['history'].append(dict(time=now(),action='发现反例',reason=reason))
                # 案例被推翻时同时降低关联流程可信度，避免旧流程继续作为已确认规则使用。
                if r['kind']=='case':
                    for linked in self.records():
                        if linked['kind']=='procedure' and r['id'] in linked.get('caseIds',[]):
                            linked['status']='待复核'
                            linked['history'].append(dict(time=now(),action='来源案例待复核',source=r['id']))
                            self.save(linked)
            elif command=='revise':
                r=self.get(identifier)
                require(r['kind'] in ['case','procedure'],'仅案例或流程可修订')
                updates=value.get('changes')
                allowed={'title','symptom','environment','tags','hypothesis','resolution','limitations'} if r['kind']=='case' else {'title','symptom','environment','tags','applicability','exclusions','conclusionCriteria','steps'}
                require(isinstance(updates,dict) and bool(updates) and set(updates)<=allowed,'修订字段不合法')
                r['history'].append(dict(time=now(),action='修订',reason=text(value,'reason'),previous={k:r.get(k) for k in updates}))
                r.update(updates)
                r['status']='待确认'
                r['version']=r.get('version',1)+1
                if r['kind']=='case':
                    # 来源结论发生变化时，旧流程必须重新核对，不继承历史确认状态。
                    for linked in self.records():
                        if linked['kind']=='procedure' and r['id'] in linked.get('caseIds',[]):
                            linked['status']='待复核'
                            linked['history'].append(dict(time=now(),action='来源案例已修订',source=r['id']))
                            self.save(linked)
            else:
                raise ValueError('不支持的写操作')
            r['history'].append(dict(time=now(),action=command))
            return self.save(r)

    def search(self, query):
        """按词语和中文相邻双字召回，显式显示可信状态，不推断结论。"""
        terms=set(re.findall(r'[a-zA-Z0-9_]+|[\u4e00-\u9fff]+',query.lower()))
        for term in list(terms):
            if re.fullmatch(r'[\u4e00-\u9fff]+',term):
                terms.update(term[i:i+2] for i in range(len(term)-1))
        found=[]
        for r in self.records():
            if r['kind']=='run':
                continue
            summary=' '.join(str(r.get(k,'')) for k in ['title','symptom','tags','applicability','hypothesis']).lower()
            score=sum(len(term) for term in terms if term in summary)
            if score:
                found.append(dict(id=r['id'],title=r['title'],status=r['status'],kind=r['kind'],
                                  environment=r['environment'],score=score,updatedAt=r['updatedAt']))
        return sorted(found,key=lambda x:(x['score'],x['status']=='已确认'),reverse=True)[:10]


def main():
    """CLI 输入中文结构化内容，输出 JSON；支持替换根目录进行隔离测试。"""
    parser=argparse.ArgumentParser(description='NPL 故障案例与排查流程管理')
    parser.add_argument('--root',default='/Users/zhangjialin/IdeaProjects/agilestar/npl-js/.troubleshoot',help='经验库目录')
    parser.add_argument('command',choices=['init','search','get','start','check','save-case','confirm','promote','flag','revise'])
    parser.add_argument('--input',help='中文 JSON 说明文件')
    parser.add_argument('--id',help='目标记录 ID')
    parser.add_argument('--query',help='检索症状或关键词')
    parser.add_argument('--confirmed-by',help='用户明确确认时填写确认人')
    parser.add_argument('--confirmation',help='用户确认原话，不得由 AI 代写确认意见')
    args=parser.parse_args()
    try:
        library=Library(args.root)
        if args.command=='search':
            require(bool(args.query),'请提供检索词')
            result=library.search(args.query)
        elif args.command=='get':
            result=library.get(args.id or '')
        else:
            value=read_input(args.input) if args.input else {}
            result=library.mutate(args.command,value,args.id,args.confirmed_by,args.confirmation)
        print(json.dumps({'ok':True,'result':result},ensure_ascii=False,indent=2))
        return 0
    except (ValueError,OSError,TypeError,KeyError) as error:
        # 外部解析和 I/O 异常不输出原文、路径或潜在凭据。
        message=str(error) if type(error) is ValueError else f'操作失败（{type(error).__name__}），请检查输入和记录 ID'
        print(json.dumps({'ok':False,'error':message},ensure_ascii=False))
        return 1


if __name__=='__main__':
    sys.exit(main())
