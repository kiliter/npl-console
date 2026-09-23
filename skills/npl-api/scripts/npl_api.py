#!/usr/bin/env python3
"""NPL 六个接口的命令入口；标准输出始终为处理后的 JSON。"""
import argparse
import json
import os
import re
import sys
import ssl
import socket
import urllib.error
from pathlib import Path
from auth import token
from client import ENDPOINTS, post
from response_filter import ResponseError, filter_response


def parser():
    """为各接口限定参数，避免接受任意路径或任意请求。"""
    root = argparse.ArgumentParser(description='NPL 接口调用：解析报文并屏蔽 acceptContent')
    sub = root.add_subparsers(dest='command', required=True)
    for name in ENDPOINTS:
        p = sub.add_parser(name, help={
            'work-query':'查询工单', 'message-query':'查询报文记录', 'sign-query':'查询签字记录',
            'picture-query':'查询图片记录', 'file-download':'读取 OBS 文件', 'message-download':'下载并解析全量报文'}[name])
        p.add_argument('--config', help='认证配置文件，默认 ~/.config/npl-api/auth.json')
        p.add_argument('--base-url', help='服务地址，支持上下文路径')
        p.add_argument('--output', help='保存处理后的 JSON；图片/PDF 则保存文件字节')
        p.add_argument('--timeout', type=float, default=60, help='请求超时秒数，默认六十秒')
        if name == 'file-download':
            p.add_argument('--bucket', help='桶名，或通过配置 bucket 提供')
            p.add_argument('--object-name', required=True, help='OBS 对象名')
            p.add_argument('--ext8', default='0', help='工单 ext8，默认 0')
            p.add_argument('--kind', choices=['text','pdf','image'], required=True, help='预期文件类型')
        else:
            p.add_argument('--case-no', help='业务单据号')
            if name.endswith('query'):
                p.add_argument('--sys-accept', help='受理流水')
                p.add_argument('--month', help='业务月份 YYYY-MM')
            if name == 'work-query':
                p.add_argument('--phone-no', help='手机号')
                p.add_argument('--start-month', help='跨月起始月份 YYYY-MM')
                p.add_argument('--end-month', help='跨月结束月份 YYYY-MM，最多十二个月')
            if name == 'picture-query':
                p.add_argument('--pic-seq', help='图片序号，正整数')
    return root


def month(value):
    """校验月份并转为服务端分表格式。"""
    if not re.fullmatch(r'\d{4}-(0[1-9]|1[0-2])', value or '') or value.startswith('0000'):
        raise ValueError('月份格式必须为 YYYY-MM')
    return value.replace('-', '')


def bodies(args, config):
    """复用项目查询约束；跨月逐月发送，保留每个月的独立响应。"""
    if args.command == 'file-download':
        bucket = args.bucket or os.environ.get('NPL_BUCKET') or config.get('bucket')
        if not bucket:
            raise ValueError('请提供桶名；可根据工单 regionCode 使用 receipt加地区编码')
        if args.kind != 'text' and not args.output:
            raise ValueError('下载 PDF 或图片必须指定 --output')
        return [dict(bucketName=bucket, objectName=args.object_name, ext8=args.ext8)]
    if args.command == 'message-download':
        if not args.case_no:
            raise ValueError('全量报文下载必须提供 --case-no')
        return [dict(caseNo=args.case_no)]
    body = {}
    for name, key in [('case_no','caseNo'),('sys_accept','sysAccept'),('phone_no','phoneNo'),('pic_seq','picSeq')]:
        value = getattr(args,name,None)
        if value:
            body[key] = value.strip()
    if 'picSeq' in body and (not body['picSeq'].isdigit() or int(body['picSeq']) <= 0):
        raise ValueError('图片序号必须为正整数')
    if 'phoneNo' in body and ('caseNo' in body or 'sysAccept' in body):
        raise ValueError('手机号查询不能与单据号或受理流水混用')
    start, end = getattr(args,'start_month',None), getattr(args,'end_month',None)
    if start or end:
        if not start or not end or args.month or 'caseNo' in body or not ('phoneNo' in body or 'sysAccept' in body):
            raise ValueError('跨月查询需手机号或受理流水和完整起止月份，不能混用单据号或单月参数')
        month(start); month(end)
        lo = int(start[:4])*12+int(start[5:])-1
        hi = int(end[:4])*12+int(end[5:])-1
        if not 0 <= hi-lo < 12:
            raise ValueError('起止月份必须递增，最多十二个月')
        return [dict(body, opMonth=f'{i//12:04}{i%12+1:02}') for i in range(lo,hi+1)]
    if args.month:
        body['opMonth'] = month(args.month)
    if not body:
        raise ValueError('至少提供一个查询条件')
    if 'phoneNo' in body and 'opMonth' not in body:
        raise ValueError('手机号查询需要月份')
    if 'sysAccept' in body and 'caseNo' not in body and 'opMonth' not in body:
        raise ValueError('受理流水查询需要月份')
    return [body]


def binary_kind(raw):
    """使用文件魔数识别，避免把错误 JSON 保存成图片或 PDF。"""
    if raw.startswith(b'%PDF-'):
        return 'pdf'
    if raw.startswith((b'\x89PNG\r\n\x1a\n',b'\xff\xd8\xff',b'GIF87a',b'GIF89a',b'BM')) or (raw[:4]==b'RIFF' and raw[8:12]==b'WEBP'):
        return 'image'
    return None


def handle(args, config, body):
    """单次响应独立解析和过滤；失败也不旁路输出未经处理的正文。"""
    base = args.base_url or os.environ.get('NPL_BASE_URL') or config.get('baseUrl')
    if not base:
        raise ValueError('请配置 baseUrl 或 NPL_BASE_URL')
    verify_tls=config.get('verifyTls',True)
    if not isinstance(verify_tls,bool):
        raise ValueError('verifyTls 必须为 JSON 布尔值')
    status, raw, mime, duration = post(base,args.command,body,token(config),args.timeout,verify_tls=verify_tls)
    result = dict(endpoint=ENDPOINTS[args.command], httpStatus=status, durationMs=duration,
                  responseBytes=len(raw), request=body, ok=200<=status<300)
    if result['ok'] and args.command == 'file-download' and args.kind != 'text':
        if binary_kind(raw) != args.kind:
            raise ResponseError('文件类型与预期不符；未写入原始内容')
        path = Path(args.output).expanduser().resolve()
        # 排他创建，防止无意覆盖已有下载或配置文件。
        with path.open('xb') as stream:
            stream.write(raw)
        result['response'] = dict(filePath=str(path),contentType=mime,bytes=len(raw))
    else:
        try:
            result['response'] = filter_response(raw, require_json=result['ok'] and args.command!='file-download')
            if result['ok'] and args.command.endswith('query') and not isinstance(result['response'],list):
                raise ResponseError('查询接口未返回预期数组')
            if args.command=='message-download' and result['ok']:
                value=result['response']
                if not isinstance(value,dict) or 'result' not in value or 'data' not in value:
                    raise ResponseError('全量报文接口未返回预期信封')
                result['ok'] = str(value['result'])=='0'
            if isinstance(result['response'],list):
                result['count']=len(result['response'])
        except ResponseError as error:
            result['ok']=False
            result['error']=str(error)
            result.pop('response',None)
    return result


def run(argv=None):
    """标准输出只包含结果；异常仅输出类型，防止第三方库夹带凭据。"""
    args=parser().parse_args(argv)
    try:
        if args.timeout<=0:
            raise ValueError('超时必须大于零')
        config={}
        config_path=args.config or os.environ.get('NPL_CONFIG')
        default_path=Path.home()/'.config/npl-api/auth.json'
        if config_path or default_path.exists():
            path=Path(config_path).expanduser().resolve() if config_path else default_path.resolve()
            config=json.loads(path.read_text())
            if not isinstance(config,dict):
                raise ValueError('配置必须是 JSON 对象')
            # 内部路径只用于相对密钥定位，不进入请求或输出。
            config['_configDir']=str(path.parent)
        requests=bodies(args,config)
        results=[]
        for body in requests:
            try:
                results.append(handle(args,config,body))
            except urllib.error.URLError as error:
                # 仅暴露原因类型与固定说明，避免底层异常携带地址或凭据。
                reason=error.reason
                if isinstance(reason,ssl.SSLCertVerificationError):
                    explanation='HTTPS 证书验证失败，请检查可信 CA 或网络代理证书'
                elif isinstance(reason,socket.gaierror):
                    explanation='服务域名解析失败，请检查 DNS 或网络连接'
                elif isinstance(reason,(TimeoutError,socket.timeout)):
                    explanation='连接超时，请检查网络、VPN 或服务可达性'
                else:
                    explanation='网络连接失败，请检查代理、VPN 或服务可达性'
                results.append(dict(ok=False,endpoint=ENDPOINTS[args.command],request=body,
                                    error=explanation,reasonType=type(reason).__name__))
            except Exception as error:
                # 网络或认证库异常不包含消息，避免异常文本泄露密钥或响应原文。
                results.append(dict(ok=False,endpoint=ENDPOINTS[args.command],request=body,
                                    error=f'调用失败（{type(error).__name__}）；请检查配置、认证及网络'))
        output=results[0] if len(results)==1 else dict(ok=all(r['ok'] for r in results),results=results)
        if args.output and not (args.command=='file-download' and args.kind!='text'):
            path=Path(args.output).expanduser().resolve()
            with path.open('x',encoding='utf-8') as stream:
                json.dump(output,stream,ensure_ascii=False,indent=2)
        print(json.dumps(output,ensure_ascii=False,indent=2))
        return 0 if output['ok'] else 1
    except Exception as error:
        print(json.dumps(dict(ok=False,error=f'参数或输出失败（{type(error).__name__}）；请检查参数、配置与输出路径'),ensure_ascii=False))
        return 1


if __name__=='__main__':
    sys.exit(run())
