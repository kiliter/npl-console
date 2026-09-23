"""凭据从用户的外部配置或环境读取，不打印、不写入技能目录。"""
import base64
import json
import os
import time
from pathlib import Path


def token(config):
    """优先使用环境中的临时 JWT，否则按项目声明签署二十分钟 RS256 JWT。"""
    supplied = os.environ.get('NPL_TOKEN')
    if supplied:
        return supplied
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    path = os.environ.get('NPL_KEY_FILE') or config.get('keyFile')
    if not path:
        raise ValueError('请配置 NPL_KEY_FILE 或 NPL_TOKEN')
    # 相对密钥路径以 auth.json 所在目录为基准，不受调用工作目录影响。
    key_path = Path(path).expanduser()
    if not key_path.is_absolute():
        key_path = Path(config.get('_configDir', Path.cwd())) / key_path
    data = key_path.read_bytes()
    store_password = os.environ.get('NPL_STORE_PASSWORD', config.get('storePassword', ''))
    key_password = os.environ.get('NPL_KEY_PASSWORD', config.get('keyPassword', ''))
    if data[:4] == bytes.fromhex('feedfeed'):
        import jks
        store = jks.KeyStore.loads(data, store_password, try_decrypt_keys=False)
        alias = os.environ.get('NPL_KEY_ALIAS') or config.get('keyAlias')
        if not alias:
            if len(store.private_keys) != 1:
                raise ValueError('密钥库有多个私钥，请配置 NPL_KEY_ALIAS')
            alias = next(iter(store.private_keys))
        key_entry = store.private_keys[alias]
        key_entry.decrypt(key_password or store_password)
        key = serialization.load_der_private_key(key_entry.pkey_pkcs8, password=None)
    else:
        password = key_password
        loader = serialization.load_pem_private_key if data.startswith(b'-----') else serialization.load_der_private_key
        key = loader(data, password=password.encode() if password else None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise ValueError('需要 RSA 私钥')
    login = os.environ.get('NPL_LOGIN_NO') or config.get('loginNo')
    channel = os.environ.get('NPL_CHANNEL') or config.get('channel')
    if not login or not channel:
        raise ValueError('请配置 loginNo 和 channel')
    def encode(value):
        """使用无填充 Base64URL，与项目 JWT 编码一致。"""
        return base64.urlsafe_b64encode(value).rstrip(b'=')
    now = int(time.time())
    claims = dict(loginNo=login, channelCode=channel, iss=channel, sub='token', aud='az', iat=now, exp=now+1200)
    signing = encode(b'{"alg":"RS256"}') + b'.' + encode(json.dumps(claims,separators=(',',':')).encode())
    signature = key.sign(signing, padding.PKCS1v15(), hashes.SHA256())
    return (signing+b'.'+encode(signature)).decode()
