"""用本机 Chrome 检查独立 HTML 的关键交互，不访问业务服务。"""
from pathlib import Path
from playwright.sync_api import sync_playwright, expect


def verify():
    """验证审批、取消、报告与移动布局，并保留可审阅截图。"""
    root = Path(__file__).resolve().parent
    with sync_playwright() as runtime:
        browser = runtime.chromium.launch(
            executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            headless=True,
        )
        page = browser.new_page(viewport={'width': 1440, 'height': 1100})
        errors, remote_requests = [], []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('request', lambda request: remote_requests.append(request.url)
                if request.url.startswith(('https:', 'http:')) else None)
        page.goto(root.joinpath('index.html').as_uri())
        page.screenshot(path=str(root / 'desktop.png'), full_page=True)
        page.locator('[data-evidence="E02"]:visible').first.click()
        expect(page.locator('#evidenceDialog')).to_be_visible()
        page.keyboard.press('Escape')
        page.locator('#send').click()
        expect(page.locator('#approve')).to_be_visible()
        page.locator('#approve').click()
        page.locator('[data-tab="report"]').click()
        expect(page.locator('#content')).to_contain_text('证据不足 · 根因待确认')
        with page.expect_download() as download:
            page.locator('#export').click()
        content = Path(download.value.path()).read_text()
        assert '模拟' in content and 'E04' in content
        page.screenshot(path=str(root / 'report.png'), full_page=True)
        page.locator('#send').click()
        expect(page.locator('#reject')).to_be_visible()
        page.locator('#reject').click()
        page.locator('[data-tab="report"]').click()
        expect(page.locator('#content')).to_contain_text('用户已拒绝模拟敏感读取')
        page.locator('#send').click()
        page.locator('#stop').click()
        expect(page.locator('#status')).to_have_text('已停止')
        page.wait_for_timeout(1700)
        expect(page.locator('#status')).to_have_text('已停止')
        page.locator('#newTop').click()
        page.locator('[name="problem"]').fill('<img src=x onerror=alert(1)> 自定义故障')
        page.locator('#newForm button[type="submit"]').click()
        expect(page.locator('#approve')).to_be_visible()
        assert page.locator('#content img').count() == 0
        page.locator('#direction').fill('请核对同一工单的业务月份')
        page.locator('#send').click()
        expect(page.locator('#content')).to_contain_text('请核对同一工单的业务月份')
        page.locator('#file').set_input_files({'name': '演示日志.txt', 'mimeType': 'text/plain', 'buffer': b'demo'})
        expect(page.locator('#attachmentList')).to_contain_text('演示日志.txt')
        page.locator('#reject').click()
        page.locator('#historySearch').fill('不存在的记录')
        expect(page.locator('#history')).to_contain_text('没有匹配')
        page.locator('#historySearch').fill('')
        page.locator('[data-history="1"]').click()
        page.locator('#sourcesNav').click()
        expect(page.locator('#sourcesView')).to_contain_text('一个业务项目，两个代码源')
        page.locator('#returnInvestigation').click()
        page.locator('#workNav').click()
        page.locator('#fromWork').click()
        expect(page.locator('[name="caseNo"]')).to_have_value('DEMO-20260920-0086')
        page.keyboard.press('Escape')
        for width in (1024, 390):
            page.set_viewport_size({'width': width, 'height': 844})
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), width
            page.locator('[data-tab="evidence"]').click()
            page.locator('[data-evidence="E02"]').click()
            expect(page.locator('#evidenceDialog')).to_be_visible()
            page.keyboard.press('Escape')
            page.locator('[data-tab="timeline"]').click()
        page.screenshot(path=str(root / 'mobile.png'), full_page=True)
        assert not errors, errors
        assert not remote_requests, remote_requests
        print('通过：证据、审批允许/拒绝、报告导出、停止终态、新建、输入转义、补充、附件名、历史、项目页、工单带入、1024/390 布局；无脚本错误与远程请求。')
        browser.close()


if __name__ == '__main__':
    verify()
