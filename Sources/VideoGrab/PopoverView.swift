import SwiftUI

// MARK: - 品牌主题

private enum Theme {
    // 蓝→靛蓝渐变，呼应 App 图标
    static let brand = LinearGradient(
        colors: [Color(red: 0.31, green: 0.55, blue: 0.96),
                 Color(red: 0.42, green: 0.34, blue: 0.93)],
        startPoint: .top, endPoint: .bottom)

    // 卡片顶部高光描边：上缘亮、下缘隐入
    static let highlight = LinearGradient(
        colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
        startPoint: .top, endPoint: .bottom)

    // 投影统一用中性深色
    static let shadow = Color.black.opacity(0.35)

    static let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
    static let field = RoundedRectangle(cornerRadius: 10, style: .continuous)
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    @State private var showCoreHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            linkField


            qualitySelector

            saveRow

            actionArea

            resultArea

            if state.showUpdateBanner {
                updateBanner
            }

            if !state.updateMessage.isEmpty {
                updateMessageRow
            }

            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .animation(.snappy(duration: 0.28), value: state.isDownloading)
        .animation(.easeInOut(duration: 0.2), value: state.lastError)
        .animation(.easeInOut(duration: 0.2), value: state.lastFinishedName)
        .animation(.easeInOut(duration: 0.2), value: state.queueSummary)
        .animation(.easeInOut(duration: 0.2), value: state.showUpdateBanner)
        .onAppear { state.refreshFromClipboard() }
    }

    private var linkCount: Int {
        Sites.allURLs(in: state.urlText).count
    }


    // MARK: - 顶部品牌

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brand)
                    .frame(width: 38, height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.highlight, lineWidth: 0.6))
                    .shadow(color: Theme.shadow, radius: 6, y: 2)
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: -1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("VideoGrab")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("视频下载器")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isDownloading {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.brand)
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
    }

    // MARK: - 链接输入

    private var linkField: some View {
        Group {
            if state.linkLines.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("复制视频链接后自动加入，也可直接粘贴", text: state.urlBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(state.isDownloading || state.isUpdatingApp)
                    clipboardWatchButton
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    if estimatedRowsHeight > listMaxHeight {
                        ScrollView(.vertical) {
                            rowsList
                        }
                        .frame(height: listMaxHeight)
                        .scrollIndicators(.automatic)
                    } else {
                        rowsList
                    }

                    HStack(spacing: 12) {
                        Text("\(linkCount) 条链接")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        clipboardWatchButton
                        if !state.isDownloading {
                            Button {
                                state.clearLinks()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("清空全部")
                        }
                        Button {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                state.replaceURLText(s)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("用剪贴板内容替换")
                        .disabled(state.isDownloading)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.035))
                }
            }
        }
        .background(Theme.field.fill(.quaternary.opacity(0.6)))
        .overlay(Theme.field.strokeBorder(Theme.highlight, lineWidth: 0.6))
        .clipShape(Theme.field)
        .animation(.snappy(duration: 0.2), value: state.linkLines.count)
    }

    private var clipboardWatchButton: some View {
        Button {
            state.setClipboardWatch(!state.clipboardWatchEnabled)
        } label: {
            Image(systemName: state.clipboardWatchEnabled ? "clipboard.fill" : "clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(state.clipboardWatchEnabled ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .help(state.clipboardWatchEnabled ? "关闭剪贴板自动收集" : "开启剪贴板自动收集")
        .disabled(state.isDownloading)
    }

    private var rowsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.linkLines.enumerated()), id: \.element.id) { idx, line in
                if idx > 0 {
                    Divider()
                        .overlay(Color.primary.opacity(0.08))
                        .padding(.leading, 36)
                }
                HStack(alignment: .center, spacing: 9) {
                    Text("\(idx + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Theme.brand.opacity(0.14)))
                    TextField("", text: state.lineBinding(line.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(state.isDownloading)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // 列表可用的最大高度：随屏幕变化（预留弹窗其余内容 + 菜单栏/边距约 360pt）
    private var listMaxHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(180, visible - 360)
    }

    // 行列表总高的估算：12pt 字约 15pt 行高 + 16pt 上下边距；
    // 长链接按每行约 46 个字符折行（360pt 宽减去序号与边距后，12pt 字符均宽约 6.5pt）。
    // 估算只用于「平铺 vs 滚动」的切换，误差一两行无碍。
    private var estimatedRowsHeight: CGFloat {
        let rows = state.linkLines.map(\.text)
        let body = rows.reduce(CGFloat(0)) { total, row in
            let lines = max(1, (row.count + 45) / 46)
            return total + CGFloat(16 + lines * 15)
        }
        let dividers = CGFloat(max(0, rows.count - 1)) * 0.5
        return body + dividers
    }

    // MARK: - 画质选择

    private var qualitySelector: some View {
        HStack(spacing: 6) {
            ForEach(Quality.allCases) { q in
                qualityChip(q)
            }
        }
    }

    private func qualityChip(_ q: Quality) -> some View {
        let selected = state.quality == q
        return Button {
            state.quality = q
        } label: {
            VStack(spacing: 3) {
                Image(systemName: q.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(q.shortLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.brand)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.highlight, lineWidth: 0.6))
                        .shadow(color: Theme.shadow, radius: 3, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(state.isDownloading)
        .animation(.snappy(duration: 0.18), value: selected)
    }

    // MARK: - 保存目录

    private var saveRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.brand)
            Text(state.saveDir.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Text(state.saveDir.path)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            Button("更改") { state.chooseSaveDir() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .disabled(state.isDownloading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Theme.field.fill(.quaternary.opacity(0.45)))
        .overlay(Theme.field.strokeBorder(Theme.highlight, lineWidth: 0.6))
    }

    // MARK: - 主操作区（下载 / 进度）

    @ViewBuilder
    private var actionArea: some View {
        if state.isDownloading {
            downloadingCard
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
            let enabled = linkCount >= 1
            Button {
                state.startDownload()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .bold))
                    Text(linkCount > 1 ? "开始下载（\(linkCount) 个链接）" : "开始下载")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(enabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(enabled ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.quaternary.opacity(0.7)))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Theme.highlight, lineWidth: 0.6))
                        .shadow(color: enabled ? Theme.shadow : .clear, radius: 8, y: 3)
                }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .animation(.easeInOut(duration: 0.2), value: enabled)
        }
    }

    private var downloadingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(progressTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if state.progress >= 0 {
                    Text("\(Int(state.progress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                        .contentTransition(.numericText())
                }
            }

            // 自定义进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.7))
                    Capsule()
                        .fill(Theme.brand)
                        .frame(width: state.progress >= 0
                               ? max(6, geo.size.width * state.progress)
                               : geo.size.width * 0.35)
                        .animation(.easeInOut(duration: 0.25), value: state.progress)
                }
            }
            .frame(height: 6)

            HStack(spacing: 6) {
                Text(state.statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    state.cancelDownload()
                } label: {
                    Text("取消")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.card.fill(.quaternary.opacity(0.45)))
        .overlay(Theme.card.strokeBorder(Theme.highlight, lineWidth: 0.6))
    }

    private var progressTitle: String {
        var base: String
        if state.progress < 0 {
            base = "准备中…"
        } else if state.progress >= 0.999 {
            base = "处理中…"
        } else {
            base = "下载中"
        }
        // 队列模式：标题带上「第 n/N 个」
        if state.queueTotal > 0 {
            base = "第 \(state.queueIndex)/\(state.queueTotal) 个 · \(base)"
        }
        return base
    }

    // MARK: - 结果 / 错误

    @ViewBuilder
    private var resultArea: some View {
        if let summary = state.queueSummary {
            queueSummaryCard(summary)
        }
        if !state.lastFinishedName.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("下载完成")
                        .font(.system(size: 12, weight: .semibold))
                    Text(state.lastFinishedName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(state.saveDir)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .help("在访达中打开")
            }
            .padding(10)
            .background(Theme.card.fill(Color.green.opacity(0.12)))
            .overlay(Theme.card.strokeBorder(Theme.highlight, lineWidth: 0.6))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if !state.lastError.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                // 报错可能很长：限高滚动显示，完整可选可复制，避免溢出遮住底部按钮
                ScrollView(.vertical) {
                    Text(state.lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            .padding(10)
            .background(Theme.card.fill(Color.orange.opacity(0.12)))
            .overlay(Theme.card.strokeBorder(Theme.highlight, lineWidth: 0.6))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func queueSummaryCard(_ s: QueueSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: s.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(s.failed == 0 ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.failed == 0 ? "队列下载成功" : "队列下载完成")
                        .font(.system(size: 12, weight: .semibold))
                    Text(s.failed == 0 ? "共 \(s.succeeded) 个，全部下载完成"
                                        : "成功 \(s.succeeded) 个，失败 \(s.failed) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(state.saveDir)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .foregroundStyle(s.failed == 0 ? Color.green : Color.orange)
                .help("在访达中打开")
            }
            // 失败明细：限高滚动、可选中复制
            if !s.failures.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(s.failures.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 90)
            }
        }
        .padding(10)
        .background(Theme.card.fill((s.failed == 0 ? Color.green : Color.orange).opacity(0.12)))
        .overlay(Theme.card.strokeBorder(Theme.highlight, lineWidth: 0.6))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                state.updateCore()
            } label: {
                HStack(spacing: 4) {
                    if state.updatingCore {
                        ProgressView().controlSize(.mini)
                        Text("更新中…")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("更新内核")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(state.updatingCore || state.isDownloading)

            Button {
                showCoreHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(showCoreHelp ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCoreHelp, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(Theme.brand)
                        Text("什么是「更新内核」？")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("「内核」即下载引擎 yt-dlp，真正负责抓取视频。视频网站经常改版导致下载失败，点「更新内核」升级到最新版通常即可修复。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("更新从 GitHub 拉取，自动走本地代理或直连，无需重装 App。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 260)
            }

            if !state.coreVersion.isEmpty {
                Text("yt-dlp \(state.coreVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                state.checkForUpdates()
            } label: {
                HStack(spacing: 4) {
                    if state.checkingUpdate {
                        ProgressView().controlSize(.mini)
                        Text("检查中…")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("检查更新")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(state.checkingUpdate || state.isDownloading || state.isUpdatingApp)
            .help("检查 VideoGrab 是否有新版本（GitHub Releases）")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("退出")
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var updateBanner: some View {
        switch state.updateFlow {
        case .idle:
            EmptyView()
        case .available(let release):
            availableUpdateBanner(release)
        case .downloading(let p):
            updatingBanner(title: "正在下载更新",
                           subtitle: p > 0 ? "\(Int(p * 100))%" : "连接中…",
                           progress: p,
                           cancellable: true)
        case .installing:
            updatingBanner(title: "正在安装并重启…", subtitle: "请稍候", progress: 1, cancellable: false)
        }
    }

    private func availableUpdateBanner(_ release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text("新版本 v\(release.version) 可用（当前 v\(UpdateChecker.currentVersion)）")
                        .font(.system(size: 12, weight: .semibold))
                    Text(release.canAutoUpdate ? "一键安装并重启，或前往网页下载"
                                               : "此版本请前往网页下载")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    state.dismissRelease()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("忽略")
            }
            HStack(spacing: 8) {
                if release.canAutoUpdate {
                    Button {
                        state.startAutoUpdate()
                    } label: {
                        Text("立即更新")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(Theme.brand))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isDownloading)
                }
                Button {
                    state.openReleasePage()
                } label: {
                    Text("网页下载")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.card.fill(Theme.brand.opacity(0.12)))
        .overlay(Theme.card.strokeBorder(Theme.highlight, lineWidth: 0.6))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func updatingBanner(title: String, subtitle: String, progress: Double, cancellable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if cancellable {
                    Button("取消") { state.cancelAutoUpdate() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.7))
                    Capsule()
                        .fill(Theme.brand)
                        .frame(width: max(6, geo.size.width * max(progress, 0.05)))
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(Theme.card.fill(Theme.brand.opacity(0.12)))
        .overlay(Theme.card.strokeBorder(Theme.highlight, lineWidth: 0.6))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // 「已是最新」/检查失败：几秒后自动消失的提示行
    private var updateMessageRow: some View {
        HStack(spacing: 5) {
            Image(systemName: state.updateIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(state.updateIsError ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.green))
            Text(state.updateMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
