"""固定六个 POST 接口；禁止重定向，错误响应同样交由过滤器处理。"""
import json
import time
import urllib.request
import urllib.error
import ssl
import certifi
from urllib.parse import urlsplit, urlencode

ENDPOINTS = {
    'work-query': '/api/wo/queryList',
    'message-query': '/api/wobiz/queryList',
    'sign-query': '/api/wosign/queryList',
    'picture-query': '/api/wopic/queryList',
    'file-download': '/test/un_look',
    'message-download': '/agapi/biz/downloadBiz',
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """禁止认证信息通过自动重定向传递到其他地址。"""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post(base, command, body, jwt, timeout=60, verify_tls=True):
    """返回状态、字节和类型，不记录认证头或原始响应。"""
    parsed = urlsplit(base)
    if parsed.scheme not in ('http', 'https') or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('baseUrl 必须是无凭据、查询参数和片段的 HTTP/HTTPS 地址')
    form = command == 'file-download'
    payload = urlencode(body) if form else json.dumps(body, ensure_ascii=False)
    mime = 'application/x-www-form-urlencoded;charset=UTF-8' if form else 'application/json'
    request = urllib.request.Request(base.rstrip('/')+ENDPOINTS[command], data=payload.encode(), method='POST',
                                    headers={'Content-Type':mime, 'kkk':jwt, 'agAuthorization':jwt})
    start = time.monotonic()
    try:
        # 使用随依赖安装的可信 CA，避免 macOS 独立 Python 缺少默认证书文件。
        # 仅在用户配置明确为 false 时跳过服务端证书及主机名校验。
        context = (ssl.create_default_context(cafile=certifi.where())
                   if verify_tls else ssl._create_unverified_context())
        response = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context)).open(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.code, response.read(), response.headers.get('Content-Type', ''), round((time.monotonic()-start)*1000)
