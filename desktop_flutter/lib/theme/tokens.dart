import 'package:flutter/widgets.dart';

/// 设计系统单一事实来源。
///
/// 值取自 `docs/FRONTEND/current/FRONTEND_DESIGN_SPEC.md` §10，对应 Goal G5。
/// 这里只放「真实可渲染」的档位：字重只有 400/500/700，圆角只有 6/10/14，
/// 间距只有 4/8/12/16/24/32，颜色三层分工。最终上屏可微调，但只在此处改。
class T {
  T._();

  // —— 第一层 chrome（大面积·瓷白中性·纸张工作面）——
  static const bg = Color(0xFFFAF8FC); // 淡紫瓷白主体底
  static const surface = Color(0xFFFFFDFF); // 清透纸面（非卡片）
  static const ink = Color(0xFF2E2A33); // 柔墨字
  static const muted = Color(0xFF6F6573); // 次要文字
  static const line = Color(0xFFE7E0EB); // 分隔线 / 描边

  // —— 第二层 主色家族（草莓粉，只点焦点 CTA / 激活态）——
  static const accent = Color(0xFFF2698E); // 草莓主色（描边 / 激活）
  static const accentStrong = Color(0xFFD94E78); // 深一档（CTA 实底配白字 / hover）
  static const accentSoft = Color(0xFFFFE3EC); // 浅晕（选中 / hover 底 / 焦点环）

  // —— 第三层 罕用语义色（不作色灯，只强化「已有形状 + 文字」的状态件）——
  static const warn = Color(0xFFF2B33D); // 需配置 / 注意
  static const sky = Color(0xFF4FB6CE); // 次要交互
  static const skySoft = Color(0xFFE7F7FA); // 纸签 / 胶带的冷色材质
  static const lilacSoft = Color(0xFFF2EDF8); // 修理贴 / 次级纸面
  static const ok = Color(0xFF5FB888); // 成功（极少用）
  static const danger = Color(0xFFD74F3E); // 失败（极少用，暖砖红，远离主色粉）

  // 墨线在世界对象上的描边色（比纯黑柔，§9.3「明确墨色描边，非浑浊灰」）
  static const inkLine = Color(0xFF3A3340);

  // —— 字重：只用三档真实字重（§10.1）——
  static const fontFamily = 'TransVortexNotoSansSC';
  static const displayFontFamily = 'TransVortexDisplay';
  static const wRegular = FontWeight.w400;
  static const wMedium = FontWeight.w500;
  static const wBold = FontWeight.w700;

  // —— 圆角：仅控件 / 浮层，禁用于布局分区（§10.3）——
  static const rSm = 6.0; // 切片 / 小控件
  static const rMd = 10.0; // 按钮 / 输入
  static const rLg = 14.0; // 浮层 / 菜单

  // —— 间距：六档（§10.4）——
  static const s4 = 4.0;
  static const s8 = 8.0;
  static const s12 = 12.0;
  static const s16 = 16.0;
  static const s24 = 24.0;
  static const s32 = 32.0;

  // —— 字阶（§10.2，CJK 下限正文 ≥12px）——
  static const tFilename = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    fontWeight: wBold,
    color: ink,
    height: 1.2,
  );
  static const tCta = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: wBold,
    height: 1.0,
  );
  static const tBrand = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: wBold,
    color: ink,
  );
  static const tSection = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: wMedium,
    color: ink,
  );
  static const tBody = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: wRegular,
    color: ink,
  );
  static const tCaption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: wRegular,
    color: muted,
  );
}
