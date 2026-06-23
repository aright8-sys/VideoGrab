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

            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .animation(.snappy(duration: 0.28), value: state.isDownloading)
        .animation(.easeInOut(duration: 0.2), value: state.lastError)
        .animation(.easeInOut(duration: 0.2), value: state.lastFinishedName)
        .onAppear { state.refreshFromClipboard() }
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
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("粘贴 新片场 / YouTube / B站 / 小红书 链接", text: $state.url)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .disabled(state.isDownloading)
            if !state.url.isEmpty && !state.isDownloading {
                Button {
                    state.url = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
            Button {
                if let s = NSPasteboard.general.string(forType: .string) { state.url = s }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("从剪贴板粘贴")
            .disabled(state.isDownloading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.field.fill(.quaternary.opacity(0.6)))
        .overlay(Theme.field.strokeBorder(Theme.highlight, lineWidth: 0.6))
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
            let enabled = !state.url.trimmingCharacters(in: .whitespaces).isEmpty
            Button {
                state.startDownload()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .bold))
                    Text("开始下载")
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
        if state.progress < 0 { return "准备中…" }
        if state.progress >= 0.999 { return "处理中…" }
        return "下载中"
    }

    // MARK: - 结果 / 错误

    @ViewBuilder
    private var resultArea: some View {
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
                Text(state.lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Theme.card.fill(Color.orange.opacity(0.12)))
            .overlay(Theme.card.strokeBorder(Theme.highlight, lineWidth: 0.6))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
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
}
