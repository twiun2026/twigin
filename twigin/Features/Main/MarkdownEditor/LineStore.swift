import Foundation

/// 相对长度 B-Tree 行存储（以“路径复制的隐式 Treap”实现，按行序号隐式定位）。
///
/// 设计要点（对应指令1）：
/// 1. 叶子中的 `LineState` 几何全部为“行内相对坐标”，绝对偏移由子树 `length`（各行
///    `fullLength` 之和）前缀和按需求得。因此文本编辑后 **无需对任何行做 shift**——
///    “行偏移”这一 O(N) 操作被彻底消除，绝对位置在读取时自动重算。
/// 2. 节点不可变（所有存储属性为 `let`）。`split` / `merge` 仅在访问路径上创建
///    O(log N) 个新节点，其余子树以引用共享（结构共享 / persistence）。这使增量
///    reconcile 的「共享前缀 + 新窗口 + 共享后缀」拼接达到 O(log N)。
/// 3. Treap 优先级由 SplitMix64 从内容哈希派生，期望树高 O(log N)。
// nonisolated + Sendable：仅持有不可变 root（let），可安全跨线程读取，供后台解析引擎使用。
nonisolated final class LineStore: @unchecked Sendable {
    private final class Node {
        let line: LineState        // 行内相对几何
        let left: Node?
        let right: Node?
        let priority: UInt64       // Treap 优先级（概率平衡）
        let count: Int             // 子树行数
        let length: Int            // 子树 fullLength 之和（前缀和求绝对偏移）

        init(line: LineState, left: Node?, right: Node?, priority: UInt64) {
            self.line = line
            self.left = left
            self.right = right
            self.priority = priority
            self.count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
            self.length = line.fullLength + (left?.length ?? 0) + (right?.length ?? 0)
        }
    }

    private let root: Node?
    private init(root: Node?) { self.root = root }

    static let empty = LineStore(root: nil)

    var count: Int { root?.count ?? 0 }
    var totalLength: Int { root?.length ?? 0 }
    var isEmpty: Bool { root == nil }

    // MARK: - 构建

    /// 从相对行数组批量构建（全量解析 / 新窗口子树）。O(N log N)。
    convenience init(relativeLines: [LineState]) {
        var node: Node? = nil
        for (i, line) in relativeLines.enumerated() {
            let p = LineStore.priority(line.textHash &+ (UInt64(bitPattern: Int64(i)) &* 0x100000001B3))
            node = LineStore.merge(node, Node(line: line, left: nil, right: nil, priority: p))
        }
        self.init(root: node)
    }

    private static func priority(_ seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    // MARK: - Treap 核心（路径复制，保持不可变共享）

    private static func merge(_ a: Node?, _ b: Node?) -> Node? {
        guard let a else { return b }
        guard let b else { return a }
        if a.priority >= b.priority {
            // a 作根：b 并入 a 的右子树；沿路径新建 a，a.left 直接共享。
            return Node(line: a.line, left: a.left, right: merge(a.right, b), priority: a.priority)
        } else {
            return Node(line: b.line, left: merge(a, b.left), right: b.right, priority: b.priority)
        }
    }

    /// 按行序号 k 切分为「前 k 行」与「其余行」，路径复制。O(log N)。
    private static func split(_ node: Node?, at k: Int) -> (Node?, Node?) {
        guard let node else { return (nil, nil) }
        let leftCount = node.left?.count ?? 0
        if k <= leftCount {
            let (l, r) = split(node.left, at: k)
            return (l, Node(line: node.line, left: r, right: node.right, priority: node.priority))
        } else {
            let (l, r) = split(node.right, at: k - leftCount - 1)
            return (Node(line: node.line, left: node.left, right: l, priority: node.priority), r)
        }
    }

    // MARK: - 序列操作（结构共享）

    func prefix(_ k: Int) -> LineStore {
        let kk = max(0, min(k, count))
        return LineStore(root: LineStore.split(root, at: kk).0)
    }

    func suffix(from k: Int) -> LineStore {
        let kk = max(0, min(k, count))
        return LineStore(root: LineStore.split(root, at: kk).1)
    }

    func concat(_ other: LineStore) -> LineStore {
        LineStore(root: LineStore.merge(root, other.root))
    }

    // MARK: - 随机访问 / 定位（均 O(log N)）

    /// 第 index 行（相对几何）。
    func line(at index: Int) -> LineState {
        precondition(index >= 0 && index < count, "LineStore index out of range")
        var node = root
        var k = index
        while let n = node {
            let lc = n.left?.count ?? 0
            if k < lc { node = n.left }
            else if k == lc { return n.line }
            else { k -= lc + 1; node = n.right }
        }
        fatalError("unreachable")
    }

    /// 第 index 行的绝对起始偏移 = 前 index 行 fullLength 之和。
    func base(ofLine index: Int) -> Int {
        var node = root
        var k = index
        var acc = 0
        while let n = node {
            let lc = n.left?.count ?? 0
            if k <= lc {
                node = n.left
            } else {
                acc += (n.left?.length ?? 0) + n.line.fullLength
                k -= lc + 1
                node = n.right
            }
        }
        return acc
    }

    /// 第 index 行（绝对几何，块/内联已移到绝对坐标）。
    func absoluteLine(at index: Int) -> LineState {
        line(at: index).shifted(by: base(ofLine: index))
    }

    /// 定位包含 offset 的行序号，O(log N)。等价原 lineIndex(for:in:) 的二分。
    func lineIndex(forOffset offset: Int) -> Int {
        guard root != nil else { return 0 }
        var node = root
        var off = offset
        var idx = 0
        while let n = node {
            let ll = n.left?.length ?? 0
            if off < ll {
                node = n.left
            } else {
                let selfEnd = ll + n.line.fullLength
                if off < selfEnd || n.right == nil {
                    return idx + (n.left?.count ?? 0)
                }
                off -= selfEnd
                idx += (n.left?.count ?? 0) + 1
                node = n.right
            }
        }
        return max(0, count - 1)
    }

    // MARK: - 遍历 / 物化

    /// 从 startIndex 起中序遍历相对行（构建 reuse 指纹用）；整棵位于起点左侧的子树被剪枝。
    func forEachRelative(from startIndex: Int, _ body: (Int, LineState) -> Void) {
        var index = 0
        func walk(_ n: Node?) {
            guard let n else { return }
            if index + n.count <= startIndex { index += n.count; return }
            walk(n.left)
            if index >= startIndex { body(index, n.line) }
            index += 1
            walk(n.right)
        }
        walk(root)
    }

    /// 物化为绝对坐标的全部块（全量渲染 / containers 用），O(N)。
    func materializedBlocks() -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var base = 0
        func walk(_ n: Node?) {
            guard let n else { return }
            walk(n.left)
            for block in n.line.blocks {
                result.append(block.shifted(by: base))
            }
            base += n.line.fullLength
            walk(n.right)
        }
        walk(root)
        return result
    }
}
