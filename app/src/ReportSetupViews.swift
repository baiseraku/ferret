import Cocoa

extension AppDelegate {
    func makeReportTab() -> NSView {
        // Tab 2：分流监测
        let box2 = NSView(); box2.translatesAutoresizingMaskIntoConstraints = false
        let repOps = NSStackView(views: [
            pill("刷新分流报告", #selector(onRefreshReport), primary: true, height: 26),
            pill("复制报告", #selector(onCopyReport), height: 26),
        ])
        repOps.orientation = .horizontal
        repOps.spacing = 8
        repOps.translatesAutoresizingMaskIntoConstraints = false
        box2.addSubview(repOps)
        let repScroll = makeTextView(reportView)
        box2.addSubview(repScroll)
        NSLayoutConstraint.activate([
            repOps.topAnchor.constraint(equalTo: box2.topAnchor),
            repOps.leadingAnchor.constraint(equalTo: box2.leadingAnchor),
            repScroll.topAnchor.constraint(equalTo: repOps.bottomAnchor, constant: 10),
            repScroll.leadingAnchor.constraint(equalTo: box2.leadingAnchor),
            repScroll.trailingAnchor.constraint(equalTo: box2.trailingAnchor),
            repScroll.bottomAnchor.constraint(equalTo: box2.bottomAnchor),
        ])
        return box2
    }

    func makeSetupTab() -> NSView {
        // Tab 3：初始化说明
        let box3 = NSView(); box3.translatesAutoresizingMaskIntoConstraints = false
        let tip = NSTextField(labelWithString: "把下面整段复制给 agent 去配服务器；也可先检查服务器依赖。")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.translatesAutoresizingMaskIntoConstraints = false
        box3.addSubview(tip)
        let setupOps = NSStackView(views: [
            pill("复制给 agent", #selector(onCopySetup), primary: true, height: 26),
            pill("检查服务器依赖", #selector(onCheckServerDeps), height: 26),
        ])
        setupOps.orientation = .horizontal
        setupOps.spacing = 8
        setupOps.translatesAutoresizingMaskIntoConstraints = false
        box3.addSubview(setupOps)
        let setupScroll = makeTextView(setupView)
        box3.addSubview(setupScroll)
        NSLayoutConstraint.activate([
            tip.topAnchor.constraint(equalTo: box3.topAnchor),
            tip.leadingAnchor.constraint(equalTo: box3.leadingAnchor),
            setupOps.topAnchor.constraint(equalTo: tip.bottomAnchor, constant: 8),
            setupOps.leadingAnchor.constraint(equalTo: box3.leadingAnchor),
            setupScroll.topAnchor.constraint(equalTo: setupOps.bottomAnchor, constant: 10),
            setupScroll.leadingAnchor.constraint(equalTo: box3.leadingAnchor),
            setupScroll.trailingAnchor.constraint(equalTo: box3.trailingAnchor),
            setupScroll.bottomAnchor.constraint(equalTo: box3.bottomAnchor),
        ])
        return box3
    }
}
