import SwiftUI

struct ThemePresets {
    
    /// 默认配色（日式极简风格）
    static let simplistic = AppTheme(
        name: "Simplistic",
        bgNoteList: Color(hex: 0xFFF8F7F2),     // 日本纸质感微黄白
        textHeader: Color(hex: 0xFF1A1A1A),     // 标题文字颜色
        bgSelected:Color(hex: 0xFFD9CFBD),      //selecte folder/note item
        textMain: Color(hex: 0xFF2C2C2C),       // 柔和炭黑
        textMuted: Color(hex: 0xFF8C847D),      // 暮灰
        bgFolderList: Color(hex: 0xFFC86D56),   // 赤土陶色参考文献卡片灰色(F0F0EE)
        borderLine: Color(hex: 0xFFE0E0E0),     // 分割线颜色
        titleBlack: Color(hex: 0xFF1A1A1A),     // 纯粹的标题色
        bgNoteEditor: Color(hex: 0xFFF8F7F2),
        dragZoneBg: Color(hex: 0xFFEAE8E0),
        btnSubmit: Color(hex: 0xFF5A5A5A),
        btnDelete: Color(hex: 0xFFD4A574),
        textPrimary: Color(hex: 0xFFFFFFFF),
        textSecondary: Color(hex: 0xFF2C2C2C),
        textItalic: Color(hex: 0xFF333333), //炭黑
        textCitation: Color(hex: 0xFF8C847D),
        bgCitation: Color(hex: 0xFFEAE8E0),
        markerA: Color(hex: 0xFFFF4D4F),        // 红色标记
        markerB: Color(hex: 0xFFFFD666),        // 黄色标记
        markerC: Color(hex: 0xFF52C41A),        // 绿色标记
        markerD: Color(hex: 0xFF1890FF)         // 蓝色标记
    )
    
    /// 'Night Office'配色
    static let nightOffice = AppTheme(
        name: "Night Office",
        bgNoteList: Color(hex: 0xFF2C3E50),     // 深蓝灰背景
        textHeader: Color(hex: 0xFF5CB58F),     // 标题文字颜色
        bgSelected:Color(hex: 0xFF34495E),
        textMain: Color(hex: 0xFFECF0F1),       // 浅灰文字
        textMuted: Color(hex: 0xFFBDC3C7),      // 中灰辅助
        bgFolderList: Color(hex: 0xFFB99BDE),   // 淡紫罗兰；卡片蓝灰（34495E）
        borderLine: Color(hex: 0xFF4A5F7F),     // 蓝灰分割线
        titleBlack: Color(hex: 0xFFF5F5F5),     // 亮白标题
        bgNoteEditor: Color(hex: 0xFF2C3E50),
        dragZoneBg: Color(hex: 0xFF3D5A80),
        btnSubmit: Color(hex: 0xFF3498DB),
        btnDelete: Color(hex: 0xFFE74C3C),
        textPrimary: Color(hex: 0xFFFFFFFF),
        textSecondary: Color(hex: 0xFFECF0F1),
        textItalic: Color(hex: 0xFF5CB58F),
        textCitation: Color(hex: 0xFFBDC3C7),
        bgCitation: Color(hex: 0xFF34495E),
        markerA: Color(hex: 0xFFFF4D4F),        // 红色标记
        markerB: Color(hex: 0xFFFFD666),        // 黄色标记
        markerC: Color(hex: 0xFF52C41A),        // 绿色标记
        markerD: Color(hex: 0xFF1890FF)         // 蓝色标记
    )
    
    /// Saturday Night 配色（Bear Toothpaste）
    static let saturdayNight = AppTheme(
        name: "Saturday Night (Midnight Pro)",
        bgNoteList: Color(hex: 0xFF171A1D),     // 列表底色：极深的午夜灰（去除了过多的青色，更中立高级）
        textHeader: Color(hex: 0xFFF8FAFC),     // 标题文字：雪白（极高对比度，清晰醒目）
        bgSelected: Color(hex: 0xFF2A313A),     // 选中态：背景色的自然微微提亮（不刺眼、不突兀）
        textMain: Color(hex: 0xFFD1D5DB),       // 正文文字：柔和的灰白（降低对比度，长时间阅读绝不刺眼！）
        textMuted: Color(hex: 0xFF8B949E),      // 辅助文字：中度灰（用于日期、摘要等）
        bgFolderList: Color(hex: 0xFF101214),   // 文件夹底色：最暗的颜色（利用明暗制造空间Z轴的下沉感）
        borderLine: Color(hex: 0xFF2B323B),     // 分割线：比背景稍亮的细线
        titleBlack: Color(hex: 0xFFFFFFFF),     // 注意：暗色模式下，此变量应作为“最强亮色”使用（纯白）
        bgNoteEditor: Color(hex: 0xFF171A1D),   // 编辑器底色：与列表一致，保持书写区域的连贯
        dragZoneBg: Color(hex: 0xFF000000),     // 拖拽区：纯黑（彻底隐藏在背景中）
        btnSubmit: Color(hex: 0xFF38BDF8),      // 确认/主按钮：清透的夜空蓝（Saturday Night 的点睛之笔）
        btnDelete: Color(hex: 0xFFF87171),      // 删除按钮：柔和的珊瑚红（符合大众对危险操作的直觉，但不刺眼）
        textPrimary: Color(hex: 0xFF38BDF8),    // 强调色：与按钮同色，在暗背景上非常清晰
        textSecondary: Color(hex: 0xFF9CA3AF),  // 次要文本
        textItalic: Color(hex: 0xFFA5B4FC),     // 斜体：带有一丝极淡的紫色调，用于区分引语或特殊词汇
        textCitation: Color(hex: 0xFF768390),   // 引用文字色：比正文更深的灰
        bgCitation: Color(hex: 0xFF1D232A),     // 引用背景：微凸起的模块颜色
        markerA: Color(hex: 0xFFFF4D4F),        // 红色标记
        markerB: Color(hex: 0xFFFFD666),        // 黄色标记
        markerC: Color(hex: 0xFF52C41A),        // 绿色标记
        markerD: Color(hex: 0xFF1890FF)         // 蓝色标记
    )
    
    /// Monday Bright 配色（Bear Duotone Snow）
    static let mondayBright = AppTheme(
        name: "Kūkan (空间)",
        bgNoteList: Color(hex: 0xFFF7F6F3),     // 暖白/米灰（模仿高级和纸底色，比纯白更护眼温润）
        textHeader: Color(hex: 0xFF4A5568),     // 墨灰（比纯黑柔和，沉稳且具有日系杂志排版感）
        bgSelected: Color(hex: 0xFFEAE7E2),     // 柔和浅灰褐（选中态自然融入背景，不刺眼）
        textMain: Color(hex: 0xFF2D3748),       // 深炭灰（正文主色，长时间阅读不疲劳）
        textMuted: Color(hex: 0xFF94A3B8),      // 浅灰蓝（次要文字/日期，低调内敛）
        bgFolderList: Color(hex: 0xFFEFEEEA),   // 文件夹侧边栏底色（比主列表略深，形成自然分层）
        borderLine: Color(hex: 0xFFE2E0DB),     // 极细分割线（若有若无的边界感）
        titleBlack: Color(hex: 0xFF1A202C),     // 标题黑（深邃但不生硬）
        bgNoteEditor: Color(hex: 0xFFFFFFFF),   // 编辑器画布（纯白，提供沉浸式书写体验）
        dragZoneBg: Color(hex: 0xFFF2F1EC),     // 拖拽区背景（与整体米调融为一体）
        btnSubmit: Color(hex: 0xFF4A5568),      // 提交/确认按钮（呼应标题色，保持统一）
        btnDelete: Color(hex: 0xFFD97706),      // 删除按钮（降饱和的琥珀红/暗橘，克制而清晰）
        textPrimary: Color(hex: 0xFF319795),    // 品牌/强调色：青瓷绿（点睛之笔，极具日式东方美学）
        textSecondary: Color(hex: 0xFF4A5568),  // 次要强调色
        textItalic: Color(hex: 0xFF718096),     // 斜体/注释文字保持统一的灰阶，避免花哨
        textCitation: Color(hex: 0xFF64748B),   // 引用文字色（沉稳蓝灰）
        bgCitation: Color(hex: 0xFFF1F3F5),     // 引用块背景（极浅的冷灰，干净通透）
        markerA: Color(hex: 0xFFBDBDBD),        // 红色标记
        markerB: Color(hex: 0xFFFFD666),        // 黄色标记
        markerC: Color(hex: 0xFF52C41A),        // 绿色标记
        markerD: Color(hex: 0xFF1890FF)         // 蓝色标记
    )
    
    // 包含所有预设的数组，方便做切换列表
    static let allThemes = [simplistic, nightOffice, saturdayNight, mondayBright]
}
