import Cocoa

// 信息区域使用普通视图，避免 NSMenu 对 disabled 菜单项的统一淡化。
final class StatusSummaryView: NSView {
    let heading = NSTextField(labelWithString: "Ferret")
    let connection = NSTextField(labelWithString: "检查连接中…")
    let chart = TrafficChartView()
    let upload = NSTextField(labelWithString: "↑ 上传    —")
    let download = NSTextField(labelWithString: "↓ 下载    —")
    let total = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 304))
        func place(_ label: NSTextField, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular) {
            label.frame = NSRect(x: 18, y: y, width: 324, height: 20)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = .textColor
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
            addSubview(label)
        }
        place(heading, y: 272, size: 13, weight: .semibold)
        place(connection, y: 250, size: 12, weight: .medium)
        let divider = NSBox(frame: NSRect(x: 18, y: 238, width: 324, height: 1))
        divider.boxType = .separator
        addSubview(divider)
        place(NSTextField(labelWithString: "SSH 隧道流量 · 最近一分钟"), y: 216, size: 12, weight: .medium)
        chart.frame = NSRect(x: 0, y: 80, width: 360, height: 134)
        addSubview(chart)
        place(upload, y: 56, size: 13)
        place(download, y: 34, size: 13)
        upload.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        download.font = upload.font
        upload.textColor = TrafficChartView.uploadColor
        download.textColor = TrafficChartView.downloadColor
        place(total, y: 12, size: 11)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
