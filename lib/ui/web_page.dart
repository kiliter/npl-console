import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 应用内网页：加载内置加密链接解密后的地址，仅对目标主机放行证书校验。
class WebPage extends StatelessWidget {
  final Uri uri;
  final String title;
  const WebPage({super.key, required this.uri, required this.title});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    body: InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(uri)),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
      // 内网 IP 证书与域名不匹配：仅放行目标主机，其余证书错误照常拒绝。
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        final host = challenge.protectionSpace.host;
        return ServerTrustAuthResponse(
          action: host == uri.host
              ? ServerTrustAuthResponseAction.PROCEED
              : ServerTrustAuthResponseAction.CANCEL,
        );
      },
    ),
  );
}
