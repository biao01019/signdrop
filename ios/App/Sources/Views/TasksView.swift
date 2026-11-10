import SwiftUI

/// 05 · 任务
struct TasksView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                LargeTitleBar("任务") {
                    Button(action: { model.clearFinished() }) {
                        Text("清空已完成")
                            .font(TypeScale.button)
                            .foregroundColor(Palette.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if let task = model.task {
                    progressCard(task)
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 24.4)

                    stepsCard(task)
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 18.7)

                    cancelCard
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 19)

                    infoCard(task)
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 19.6)
                } else {
                    emptyCard
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 24.4)
                }

                Color.clear.frame(height: 150)
            }
        }
    }

    // MARK: 进度

    private func progressCard(_ task: SignTask) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(Palette.divider, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(task.progress, 0), 1)))
                    .stroke(Palette.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(task.percentText)
                    .font(Font.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                    .foregroundColor(Palette.ink)
            }
            .frame(width: 103.7, height: 103.7)
            .padding(.top, 26.7)

            Text(stepHeadline(task))
                .font(Font.system(size: 17, weight: .semibold))
                .foregroundColor(Palette.ink)
                .padding(.top, 18)

            Text(task.detailLine)
                .font(TypeScale.body)
                .foregroundColor(Palette.sub)
                .padding(.top, 7)
                .padding(.bottom, 27)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func stepHeadline(_ task: SignTask) -> String {
        if task.progress >= 1 { return "签名完成" }
        switch task.steps.first(where: { $0.state == .running })?.title {
        case "使用证书重签名": return "正在签名"
        case "解压 IPA 安装包": return "正在解压"
        case "校验描述文件": return "正在校验"
        case "打包并安装到设备": return "正在安装"
        default: return "正在处理"
        }
    }

    // MARK: 步骤

    private func stepsCard(_ task: SignTask) -> some View {
        VStack(spacing: 0) {
            ForEach(task.steps) { step in
                stepRow(step)
            }
        }
        .padding(.vertical, 8)
        .card()
    }

    private func stepRow(_ step: TaskStep) -> some View {
        HStack(spacing: 12) {
            stepIcon(step.state)
                .frame(width: 20, height: 20)

            Text(step.title)
                .font(TypeScale.rowLabel)
                .foregroundColor(color(for: step.state))

            Spacer(minLength: 8)

            Text(statusText(step.state))
                .font(TypeScale.body)
                .foregroundColor(step.state == .pending ? Palette.sub : color(for: step.state))
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 34.4)
    }

    @ViewBuilder
    private func stepIcon(_ state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19, weight: .regular))
                .foregroundColor(Palette.green)
        case .running:
            Image(systemName: "circle.dashed")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Palette.blue)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color(hex: 0xD2D2D8))
        }
    }

    private func color(for state: StepState) -> Color {
        switch state {
        case .done: return Palette.ink
        case .running: return Palette.blue
        case .pending: return Palette.sub
        }
    }

    private func statusText(_ state: StepState) -> String {
        switch state {
        case .done: return "已完成"
        case .running: return "进行中"
        case .pending: return "等待中"
        }
    }

    // MARK: 取消

    private var cancelCard: some View {
        Button(action: { model.cancelTask() }) {
            Text("取消任务")
                .font(TypeScale.cardTitle)
                .foregroundColor(Palette.red)
                .frame(maxWidth: .infinity)
                .frame(height: 45.6)
                .card(radius: 16)
        }
        .buttonStyle(RowButtonStyle())
    }

    // MARK: 信息

    private func infoCard(_ task: SignTask) -> some View {
        VStack(spacing: 0) {
            kvRow("目标设备", task.deviceName)
            DividerLine()
            kvRow("使用证书", task.certName)
            DividerLine()
            kvRow("开始时间", "今天 " + timeText(task.startedAt))
        }
        .card()
    }

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(TypeScale.rowLabel)
                .foregroundColor(Palette.sub)
            Spacer(minLength: 8)
            Text(value)
                .font(TypeScale.valueStrong)
                .foregroundColor(Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 44)
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: 空状态

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Palette.ter)
            Text("没有进行中的任务")
                .font(TypeScale.rowLabel)
                .foregroundColor(Palette.sub)
            Text("在应用页点 + 选择 IPA 即可开始签名")
                .font(TypeScale.meta)
                .foregroundColor(Palette.ter)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .card()
    }
}
