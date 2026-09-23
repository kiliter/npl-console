"""离线验证字段屏蔽、HTTP 六接口、JWT 与文件输出，不调用业务服务器。"""
import base64
import contextlib
import io
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from auth import token
from npl_api import run, bodies, parser
from response_filter import MASK, ResponseError, filter_response


class FilterTests(unittest.TestCase):
    """覆盖转义、已知错误格式、XML 及无法解析的安全失败。"""
    def test_nested(self):
        source={'result':0,'data':json.dumps({'reqData':json.dumps({'acceptContent':'秘密正文','keep':None,'items':[{'acceptContent':'其他正文','n':4}]})})}
        result=filter_response(json.dumps(source))
        self.assertEqual(result['data']['reqData'],{'acceptContent':MASK,'keep':None,'items':[{'acceptContent':MASK,'n':4}]})

    def test_malformed_embedded(self):
        raw='{"reqData":"{"woOpList":[{"acceptContent":"秘密正文","opCode":"正常"}],"extra":[]}","sibling":null}'
        result=filter_response(raw)
        self.assertEqual(result['reqData']['woOpList'][0]['acceptContent'],MASK)
        self.assertEqual(result['reqData']['woOpList'][0]['opCode'],'正常')
        self.assertIn('sibling',result)

    def test_escaped_key(self):
        self.assertEqual(filter_response(r'{"\u0061cceptContent":"秘密"}'),{'acceptContent':MASK})

    def test_xml(self):
        out=filter_response('<root><acceptContent><x>秘密</x></acceptContent><keep a="正常"/></root>',False)
        self.assertNotIn('秘密',out)
        self.assertIn('正常',out)

    def test_invalid_no_raw(self):
        for text in ['{"acceptContent":"秘密', '正文 acceptContent=秘密']:
            with self.assertRaises(ResponseError) as result:
                filter_response(text,False)
            self.assertNotIn('秘密',str(result.exception))


class SigningTests(unittest.TestCase):
    """仅生成临时测试密钥，验证声明及实际 RSA 签名。"""
    def test_pem_and_jks(self):
        import jks
        from cryptography.hazmat.primitives import serialization, hashes
        from cryptography.hazmat.primitives.asymmetric import rsa, padding
        key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        der=key.private_bytes(serialization.Encoding.DER,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
        pem=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
        with tempfile.TemporaryDirectory() as directory:
            for suffix,data in [('pem',pem),('jks',jks.KeyStore.new('jks',[jks.PrivateKeyEntry.new('test',[],der)]).saves('test-password'))]:
                path=Path(directory)/('key.'+suffix);path.write_bytes(data)
                with patch.dict(os.environ,{'NPL_KEY_FILE':str(path),'NPL_STORE_PASSWORD':'test-password'},clear=True):
                    jwt=token({'loginNo':'test','channel':'test-channel'})
                # 验证全部放在配置中、相对路径和留空私钥密码沿用库密码。
                with patch.dict(os.environ,{},clear=True):
                    configured=token({'loginNo':'test','channel':'test-channel','keyFile':path.name,
                                      '_configDir':directory,'storePassword':'test-password','keyPassword':''})
                self.assertEqual(len(configured.split('.')),3)
                header,payload,signature=jwt.split('.')
                claims=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
                self.assertEqual(claims['exp']-claims['iat'],1200)
                self.assertEqual(claims['channelCode'],'test-channel')
                key.public_key().verify(base64.urlsafe_b64decode(signature+'='*(-len(signature)%4)),(header+'.'+payload).encode(),padding.PKCS1v15(),hashes.SHA256())


class HttpTests(unittest.TestCase):
    """本地 HTTP 服务检验请求参数、响应过滤和下载字节完整性。"""
    def test_months_and_error_output(self):
        args=parser().parse_args(['work-query','--phone-no','123','--start-month','2025-12','--end-month','2026-02'])
        self.assertEqual([x['opMonth'] for x in bodies(args,{})],['202512','202601','202602'])
        with patch.dict(os.environ,{'NPL_TOKEN':'test','NPL_BASE_URL':'https://example.invalid'},clear=True):
            for response in [b'{"acceptContent":"secret","reason":"bad"}', b'{"acceptContent":"secret']:
                with patch('npl_api.post',return_value=(400,response,'application/json',1)):
                    stream=io.StringIO()
                    with contextlib.redirect_stdout(stream):
                        code=run(['work-query','--case-no','CASE'])
                    self.assertEqual(code,1)
                    self.assertNotIn('secret',stream.getvalue())

    def test_six_commands(self):
        requests=[]
        class Handler(BaseHTTPRequestHandler):
            """固定合成响应，不输出访问日志或认证头。"""
            def log_message(self,*args):
                pass

            def do_POST(self):
                body=self.rfile.read(int(self.headers['Content-Length']))
                requests.append((self.path,body,self.headers['kkk'],self.headers['agAuthorization']))
                if self.path.endswith('/un_look'):
                    data=b'%PDF-1.4\nTEST'
                elif self.path.endswith('/downloadBiz'):
                    data=json.dumps({'result':0,'data':json.dumps({'reqData':{'acceptContent':'秘密','other':[1,2]}})}).encode()
                else:
                    data=json.dumps([{'acceptContent':'秘密','other':None}]).encode()
                self.send_response(200);self.end_headers();self.wfile.write(data)
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        try:
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ,{'NPL_TOKEN':'temporary-test','NPL_BASE_URL':f'http://127.0.0.1:{server.server_port}/context'},clear=True):
                for command in ['work-query','message-query','sign-query','picture-query','message-download','file-download']:
                    options=[command,'--case-no','CASE'] if command!='file-download' else [command,'--bucket','receipt0','--object-name','CASE.pdf','--kind','pdf','--output',str(Path(directory)/'test.pdf')]
                    stream=io.StringIO()
                    with contextlib.redirect_stdout(stream):
                        code=run(options)
                    self.assertEqual(code,0,stream.getvalue())
                    self.assertNotIn('秘密',stream.getvalue())
                    self.assertNotIn('temporary-test',stream.getvalue())
                    data=json.loads(stream.getvalue())
                    if command=='message-download':
                        self.assertEqual(data['response']['data']['reqData']['other'],[1,2])
                self.assertEqual((Path(directory)/'test.pdf').read_bytes(),b'%PDF-1.4\nTEST')
                self.assertEqual(len(requests),6)
                self.assertTrue(all(x[0].startswith('/context/') and x[2]==x[3]=='temporary-test' for x in requests))
        finally:
            server.shutdown();server.server_close();worker.join()


if __name__=='__main__':
    unittest.main()
