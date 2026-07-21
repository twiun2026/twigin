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
        name: "Saturday Night",
        bgNoteList: Color(hex: 0xFF10212B),
        textHeader: Color(hex: 0xFFE7FBF7),
        bgSelected:Color(hex: 0xFF8A9A86),
        textMain: Color(hex: 0xFFE7FBF7),
        textMuted: Color(hex: 0xFF8CB7B9),
        bgFolderList: Color(hex: 0xFF183440),
        borderLine: Color(hex: 0xFF2C5363),
        titleBlack: Color(hex: 0xFFF4FFFC),
        bgNoteEditor: Color(hex: 0xFF10212B),
        dragZoneBg: Color(hex: 0xFF0B181F),
        btnSubmit: Color(hex: 0xFF58D7C4),
        btnDelete: Color(hex: 0xFFFF8F70),
        textPrimary: Color(hex: 0xFF0A1D23),
        textSecondary: Color(hex: 0xFFE7FBF7),
        textItalic: Color(hex: 0xFF4C9085),
        textCitation: Color(hex: 0xFF8CB7B9),
        bgCitation: Color(hex: 0xFF183440),
        markerA: Color(hex: 0xFFFF4D4F),        // 红色标记
        markerB: Color(hex: 0xFFFFD666),        // 黄色标记
        markerC: Color(hex: 0xFF52C41A),        // 绿色标记
        markerD: Color(hex: 0xFF1890FF)         // 蓝色标记
    )
    
    /// Monday Bright 配色（Bear Duotone Snow）
    static let mondayBright = AppTheme(
        name: "Monday Bright",
        bgNoteList: Color(hex: 0xFFFFFFFF),
        textHeader: Color(hex: 0xFF814DA4),
        bgSelected:Color(hex: 0xFFB0C4DE),
        textMain: Color(hex: 0xFF273043),
        textMuted: Color(hex: 0xFF6A768E),
        bgFolderList: Color(hex: 0xFFE6E8EB),
        borderLine: Color(hex: 0xFFD7DFEA),
        titleBlack: Color(hex: 0xFF111827),
        bgNoteEditor: Color(hex: 0xFFFFFFFF),
        dragZoneBg: Color(hex: 0xFFF0F4FA),
        btnSubmit: Color(hex: 0xFF6A768E),
        btnDelete: Color(hex: 0xFFF4A261),
        textPrimary: Color(hex: 0xFF268579),
        textSecondary: Color(hex: 0xFF273043),
        textItalic: Color(hex: 0xFFB36DB3),
        textCitation: Color(hex: 0xFF6A768B),
        bgCitation: Color(hex: 0xFFF0F4FB),
        markerA: Color(hex: 0xFFBDBDBD),        // 红色标记
        markerB: Color(hex: 0xFFFFD666),        // 黄色标记
        markerC: Color(hex: 0xFF52C41A),        // 绿色标记
        markerD: Color(hex: 0xFF1890FF)         // 蓝色标记
    )
    
    // 包含所有预设的数组，方便做切换列表
    static let allThemes = [simplistic, nightOffice, saturdayNight, mondayBright]
}
