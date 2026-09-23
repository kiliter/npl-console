/// 统一响应式断点：阈值与 design/maintenance-v2 高保真原型保持一致。
library;

/// 主布局移动 / 桌面总开关：宽度小于 700 视为移动端。
bool isMobileWidth(double width) => width < 700;

/// 桌面端左侧「查询结果」栏宽度：随屏宽加宽，利用大屏空间。
/// < 1500 → 250；1500–1849 → 290；≥ 1850 → 330。
double sidebarWidth(double width) {
  if (width >= 1850) return 330;
  if (width >= 1500) return 290;
  return 250;
}

/// 单据详情字段列数：移动端单列；桌面全宽详情按屏宽分列。
/// < 700 → 1；700–1499 → 3；1500–1849 → 3；≥ 1850 → 4。
int detailColumns(double width) {
  if (isMobileWidth(width)) return 1;
  if (width >= 1850) return 4;
  if (width >= 700) return 3;
  return 1;
}
