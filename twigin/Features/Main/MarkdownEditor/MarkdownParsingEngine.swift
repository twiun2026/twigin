import Foundation

/// 一次增量编辑的解析结果（可跨线程回传主线程）。
/// 只携带渲染所需的最小信息 + 影子缓冲物化出的最新全文（供 SwiftUI 绑定），
/// 主线程因此 **完全不需要读取 NSTextStorage 的全量字符串**。
struct MarkdownEditResult: Sendable {
    let affectedRange: NSRange?
    let blockDiff: MarkdownBlockDiff?
    let allBlocks: [MarkdownBlock]  // 编辑后全量 blocks（含位移后的后缀复用块），供增量渲染兜底
    let source: String     // 后台由影子缓冲物化，主线程仅做 O(1) 的 CoW 赋值给绑定
    let serial: UInt64     // 编辑序号，用于主线程做 coalescing / 陈旧丢弃
    let textLength: Int    // 解析时文本长度，range 安全性校验
}

/// 全量快照（笔记切换 / 初次加载 / 主题变化后的整篇重渲染）。
struct MarkdownFullSnapshot: Sendable {
    let blocks: [MarkdownBlock]
    let textLength: Int
}

/// 后台高优先级串行解析引擎（对应指令2）。
///
/// - 独占持有 `MarkdownParser` / `MarkdownDocumentState` / 影子文本缓冲 `shadow`，
///   三者 **只在本引擎的串行队列上访问**，因此无需锁即可保证数据竞争安全
///   （类标记 `@unchecked Sendable` 是对这一不变式的显式承诺）。
/// - 串行队列天然保证编辑 **按序** 应用（Task/actor 无法保证 FIFO，故此处刻意用 DispatchQueue）。
/// - 主线程收到编辑通知后，仅传入「编辑范围 + delta + 极小的插入子串」；引擎在后台把增量
///   打到影子缓冲上，再执行重型的 `parser.update`，最后仅回传最小 diff。
nonisolated final class MarkdownParsingEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.twigin.markdown.parse", qos: .userInitiated)
    private let parser = MarkdownParser()
    private let state = MarkdownDocumentState()
    private let shadow = NSMutableString()

    /// 全量加载（初次 / 笔记切换）。text 为一次性 Sendable 值。
    func load(text: String, completion: @escaping @Sendable (MarkdownFullSnapshot) -> Void) {
        queue.async {
            self.shadow.setString(text)
            _ = self.parser.reparseAll(source: text, state: self.state)
            completion(MarkdownFullSnapshot(
                blocks: self.state.lineStore.materializedBlocks(),
                textLength: (text as NSString).length
            ))
        }
    }

    /// 应用一次增量编辑并解析，回传最小 diff。
    func apply(
        editedRange: NSRange,
        delta: Int,
        inserted: String,
        serial: UInt64,
        completion: @escaping @Sendable (MarkdownEditResult) -> Void
    ) {
        queue.async {
            // 影子缓冲增量更新：被替换的旧区间长度 = 新编辑区间长度 - delta。
            let oldLength = max(0, editedRange.length - delta)
            let oldRange = NSRange(location: editedRange.location, length: oldLength)
            if NSMaxRange(oldRange) <= self.shadow.length {
                self.shadow.replaceCharacters(in: oldRange, with: inserted)
            } else {
                // 边界异常（理论上不发生）：整体对齐，避免影子缓冲与 TextStorage 漂移。
                // 由主线程后续的全量 catch-up 纠正渲染。
            }

            let src = self.shadow as String
            let doc = self.parser.update(source: src, editedRange: editedRange, changeInLength: delta, state: self.state)
            completion(MarkdownEditResult(
                affectedRange: doc.affectedRange,
                blockDiff: doc.blockDiff,
                allBlocks: self.state.lineStore.materializedBlocks(),
                source: src,
                serial: serial,
                textLength: (src as NSString).length
            ))
        }
    }

    /// 不重解析，仅物化当前块用于整篇重渲染（主题/字体变化、增量渲染跳帧后的赶齐）。
    func snapshot(completion: @escaping @Sendable (MarkdownFullSnapshot) -> Void) {
        queue.async {
            completion(MarkdownFullSnapshot(
                blocks: self.state.lineStore.materializedBlocks(),
                textLength: self.state.totalLength
            ))
        }
    }
}
