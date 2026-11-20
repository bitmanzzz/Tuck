import AppKit
import Darwin

/// 封装 macOS 27+ 统一菜单栏架构（MenuBarAgent）的原生隐藏能力。
///
/// 从 macOS 27 开始，系统将所有状态栏图标合并进 MenuBarAgent 单一合成窗口，
/// 不再为每个图标分配独立 CGWindowID，传统的 10 000 pt 宽分隔线推挤方案失效。
/// 此处通过动态加载私有框架 MenuBarClientCore 的评估模式可见性断言，
/// 按白名单（allowedBundleIdentifiers）原生控制第三方状态栏图标的显示与隐藏。
@MainActor
final class MenuBarHider {
    static let shared = MenuBarHider()

    /// 当前系统是否运行在 macOS 27 及以上的统一菜单栏架构中。
    nonisolated static let usesUnifiedMenuBar: Bool = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }()

    /// 私有框架类与核心 Selector 是否均已成功解析。
    nonisolated static let isSupported: Bool = {
        guard usesUnifiedMenuBar else { return false }
        return Runtime.shared != nil
    }()

    private var activeAssertion: NSObject?
    private var activeAllowedBundles: Set<String>?
    private var generation: UInt64 = 0

    /// 私有 API 运行时符号缓存。
    private final class Runtime: @unchecked Sendable {
        static let shared: Runtime? = Runtime()

        let configClass: NSObject.Type
        let assertionClass: NSObject.Type
        let allocSelector = NSSelectorFromString("alloc")
        let initConfigSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        let invalidateSelector = NSSelectorFromString("invalidate")

        /// 覆盖全部内置系统状态项（macOS 27.2 实测自动归一化为 0...8 共 9 类系统项），
        /// 确保时钟、控制中心、Wi-Fi、聚焦、屏幕镜像等系统图标不受影响。
        let allSystemItems: NSArray = Array(0...255) as NSArray

        private init?() {
            let path = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
            guard dlopen(path, RTLD_NOW) != nil else { return nil }
            guard
                let configClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
                let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type
            else { return nil }

            guard
                configClass.instancesRespond(to: initConfigSelector),
                assertionClass.instancesRespond(to: activateSelector),
                assertionClass.instancesRespond(to: invalidateSelector)
            else { return nil }

            self.configClass = configClass
            self.assertionClass = assertionClass
        }
    }

    private typealias ActivateIMP = @convention(c) (
        AnyObject,
        Selector,
        AnyObject,
        @convention(block) (NSError?) -> Void
    ) -> Void

    private typealias InvalidateIMP = @convention(c) (AnyObject, Selector) -> Void

    private init() {}

    /// 是否正处于可见性限制（隐藏部分图标）状态。
    var isRestricting: Bool {
        activeAllowedBundles != nil
    }

    /// 仅允许白名单内的第三方 App 在菜单栏显示（系统项与 Tuck 自身始终保留）。
    func restrict(toAllowedBundleIDs bundleIDs: Set<String>) {
        guard let runtime = Runtime.shared else { return }

        var allowed = bundleIDs
        if let ownBundleID = Bundle.main.bundleIdentifier {
            allowed.insert(ownBundleID)
        }

        // 白名单未发生变化且断言已激活时不重复发送 IPC，避免 MenuBarAgent 不必要重排。
        if activeAssertion != nil, activeAllowedBundles == allowed {
            return
        }

        generation &+= 1
        let requestGeneration = generation
        activeAllowedBundles = allowed

        guard let config = makeConfiguration(runtime: runtime, allowedBundleIDs: allowed) else { return }
        let newAssertion = runtime.assertionClass.init()
        let imp = newAssertion.method(for: runtime.activateSelector)
        let activateFn = unsafeBitCast(imp, to: ActivateIMP.self)

        // 先将 block 保存为局部变量再传入 C 函数指针，避免 Swift 将闭包当作 @noescape 导致崩溃。
        let completion: @convention(block) (NSError?) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else {
                    Self.invalidateObject(newAssertion, selector: runtime.invalidateSelector)
                    return
                }
                // 若在异步回调返回前已有更新的请求或已全部展开，立即销毁过期断言。
                guard self.generation == requestGeneration else {
                    Self.invalidateObject(newAssertion, selector: runtime.invalidateSelector)
                    return
                }
                if let error {
                    NSLog("Tuck: 激活菜单栏可见性断言失败: \(error)")
                    Self.invalidateObject(newAssertion, selector: runtime.invalidateSelector)
                    if self.activeAssertion == nil {
                        self.activeAllowedBundles = nil
                    }
                    return
                }
                let previous = self.activeAssertion
                self.activeAssertion = newAssertion
                if let previous, previous !== newAssertion {
                    Self.invalidateObject(previous, selector: runtime.invalidateSelector)
                }
            }
        }

        activateFn(newAssertion, runtime.activateSelector, config, completion)
    }

    /// 解除全部隐藏限制，恢复显示所有状态栏图标。
    func showAll() {
        generation &+= 1
        activeAllowedBundles = nil
        guard let runtime = Runtime.shared, let assertion = activeAssertion else { return }
        activeAssertion = nil
        Self.invalidateObject(assertion, selector: runtime.invalidateSelector)
    }

    private func makeConfiguration(runtime: Runtime, allowedBundleIDs: Set<String>) -> AnyObject? {
        guard let allocated = runtime.configClass.perform(runtime.allocSelector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        let sortedBundles = Array(allowedBundleIDs).sorted() as NSArray
        return allocated.perform(
            runtime.initConfigSelector,
            with: runtime.allSystemItems,
            with: sortedBundles
        )?.takeRetainedValue()
    }

    private static func invalidateObject(_ assertion: NSObject, selector: Selector) {
        let imp = assertion.method(for: selector)
        let invalidateFn = unsafeBitCast(imp, to: InvalidateIMP.self)
        invalidateFn(assertion, selector)
    }
}
