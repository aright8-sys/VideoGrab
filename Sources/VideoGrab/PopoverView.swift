import SwiftUI

struct PopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("VideoGrab").font(.headline)
                Spacer()
            }

            // 链接输入（自动从剪贴板预填）
            VStack(alignment: .leading, spacing: 4) {
                Text("视频链接").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("粘贴 新片场 / YouTube / B站 链接", text: $state.url)
                        .textFieldStyle(.roundedBorder)
                        .disabled(state.isDownloading)
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) { state.url = s }
                    } label: { Image(systemName: "doc.on.clipboard") }
                        .help("从剪贴板粘贴")
                        .disabled(state.isDownloading)
                }
            }

            // 画质
            Picker("画质", selection: $state.quality) {
                ForEach(Quality.allCases) { q in Text(q.rawValue).tag(q) }
            }
            .pickerStyle(.menu)
            .disabled(state.isDownloading)

            // 保存目录
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(state.saveDir.path)
                    .font(.caption)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("更改") { state.chooseSaveDir() }
                    .controlSize(.small)
                    .disabled(state.isDownloading)
            }

            Divider()

            // 主操作：下载 / 取消 + 进度
            if state.isDownloading {
                if state.progress < 0 {
                    ProgressView().controlSize(.small)
                } else {
                    ProgressView(value: state.progress)
                }
                HStack {
                    Text(state.statusLine).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button("取消", role: .destructive) { state.cancelDownload() }
                        .controlSize(.small)
                }
            } else {
                Button {
                    state.startDownload()
                } label: {
                    Label("下载", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.url.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // 结果 / 错误
            if !state.lastFinishedName.isEmpty {
                Label(state.lastFinishedName, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .lineLimit(2)
            }
            if !state.lastError.isEmpty {
                Text(state.lastError)
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(4).textSelection(.enabled)
            }

            Divider()

            // 底部：内核更新 + 退出
            HStack {
                Button {
                    state.updateCore()
                } label: {
                    if state.updatingCore {
                        HStack(spacing: 4) { ProgressView().controlSize(.small); Text("更新中…") }
                    } else {
                        Text("更新内核")
                    }
                }
                .controlSize(.small)
                .disabled(state.updatingCore || state.isDownloading)

                if !state.coreVersion.isEmpty {
                    Text("yt-dlp \(state.coreVersion)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { state.refreshFromClipboard() }
    }
}
