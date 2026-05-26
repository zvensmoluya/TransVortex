import type { ReactNode } from "react";
import { Captions, CheckCircle2, FileText, FileVideo, FolderOpen, Gauge, Languages, Play, ShieldCheck, Tags } from "lucide-react";
import type { EnvironmentCheck } from "../../domain/environment";
import type { ServiceConnection } from "../../domain/serviceConnection";
import type { TaskDraft } from "../../domain/task";
import { StatusBadge } from "../../components/feedback/StatusBadge";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

type NewTaskPageProps = {
  draft: TaskDraft;
  serviceConnections: ServiceConnection[];
  environmentChecks: EnvironmentCheck[];
};

export function NewTaskPage({ draft, serviceConnections, environmentChecks }: NewTaskPageProps) {
  const translationConnection = serviceConnections.find((connection) => connection.kind === "translation" && connection.isDefault);
  const asrConnection = serviceConnections.find((connection) => connection.kind === "asr" && connection.isDefault);
  const blockingChecks = environmentChecks.filter((check) => check.status === "fail");

  return (
    <div className="page-stack">
      <PageHeader
        eyebrow="制作台"
        title="准备字幕任务"
        description={`${draft.input.displayName} · ${draft.languages.sourceLanguage} → ${draft.languages.targetLanguage} · 输出 ${draft.output.formats.map((format) => format.toUpperCase()).join(" / ")}`}
        actions={
          <button className="tvx-btn tvx-btn-primary" type="button">
            <Play size={15} />
            开始任务
          </button>
        }
      />

      <div className="workspace-grid">
        <SectionPanel title="素材台面" subtitle="输入素材 · 字幕来源 · 语言">
          <div className="input-dock">
            <FileVideo size={24} />
            <div>
              <strong>{draft.input.displayName}</strong>
              <span>{draft.input.path}</span>
            </div>
            <button className="tvx-btn" type="button">
              <FolderOpen size={15} />
              选择文件
            </button>
          </div>
          <div className="subtitle-stage-preview" aria-label="字幕任务预览">
            <div className="video-rail">
              <span />
              <span />
              <span />
              <span />
              <span />
            </div>
            <div className="subtitle-sample-lines">
              <span>今日は、字幕制作の流れを確認します。</span>
              <strong>今天我们先确认字幕制作的整体流程。</strong>
            </div>
          </div>
          <div className="form-grid">
            <label>
              <span>源语言</span>
              <input className="tvx-input" value={draft.languages.sourceLanguage} readOnly />
            </label>
            <label>
              <span>目标语言</span>
              <input className="tvx-input" value={draft.languages.targetLanguage} readOnly />
            </label>
          </div>
          <div className="segmented-control" aria-label="任务类型">
            <button className="is-selected" type="button">转写并翻译</button>
            <button type="button">翻译已有字幕</button>
            <button type="button">重新导出</button>
          </div>
        </SectionPanel>

        <SectionPanel title="启动前接线" subtitle="翻译服务 · ASR 服务 · 运行环境">
          <div className="connection-rack">
            <ReadinessRow
              icon={<Languages size={18} />}
              label="翻译服务"
              detail={translationConnection ? `${translationConnection.displayName} · ${translationConnection.model}` : "未配置"}
              ok={translationConnection?.connectionStatus.state === "connected"}
            />
            <ReadinessRow
              icon={<ShieldCheck size={18} />}
              label="ASR 服务"
              detail={asrConnection ? `${asrConnection.displayName} · ${asrConnection.model}` : "未配置"}
              ok={asrConnection?.connectionStatus.state === "connected"}
            />
            <ReadinessRow
              icon={<CheckCircle2 size={18} />}
              label="环境状态"
              detail={blockingChecks.length === 0 ? "没有阻塞项" : `${blockingChecks.length} 个阻塞项`}
              ok={blockingChecks.length === 0}
            />
          </div>
        </SectionPanel>
      </div>

      <div className="workspace-grid is-wide-left">
        <SectionPanel title="制作流水线" subtitle="输入素材 → 源字幕 → 翻译 → 术语 → 质量 → 导出">
          <div className="production-lane">
            <FlowStep icon={<FileVideo size={16} />} label="输入素材" detail={draft.input.displayName} active />
            <FlowStep icon={<Captions size={16} />} label="获取源字幕" detail="生成 Segment" />
            <FlowStep icon={<Languages size={16} />} label="翻译字幕" detail={translationConnection?.model ?? "待选择模型"} />
            <FlowStep icon={<Tags size={16} />} label="术语一致性" detail={draft.terms.selectedTermBaseId ?? "未选择"} />
            <FlowStep icon={<Gauge size={16} />} label="质量检查" detail={draft.advanced.qualityMode === "balanced" ? "均衡处理" : "保守处理"} />
            <FlowStep icon={<FileText size={16} />} label="导出交付" detail={draft.output.formats.map((format) => format.toUpperCase()).join(" / ")} />
          </div>
        </SectionPanel>

        <SectionPanel title="交付托盘" subtitle="输出文件 · 字幕类型 · 项目术语 · 质量模式">
          <div className="delivery-tray">
            <SummaryItem label="输出格式" value={draft.output.formats.map((format) => format.toUpperCase()).join(" / ")} icon={<FileText size={16} />} />
            <SummaryItem label="字幕类型" value={draft.output.bilingual ? "双语字幕" : "单语字幕"} icon={<Captions size={16} />} />
            <SummaryItem label="术语表" value={draft.terms.selectedTermBaseId ?? "未选择"} icon={<Tags size={16} />} />
            <SummaryItem label="质量模式" value={draft.advanced.qualityMode === "balanced" ? "均衡处理" : "保守处理"} icon={<Gauge size={16} />} />
          </div>
        </SectionPanel>
      </div>
    </div>
  );
}

function ReadinessRow({ icon, label, detail, ok }: { icon: ReactNode; label: string; detail: string; ok: boolean }) {
  return (
    <div className="readiness-row">
      {icon}
      <div>
        <strong>{label}</strong>
        <span>{detail}</span>
      </div>
      <StatusBadge tone={ok ? "success" : "warning"} label={ok ? "可用" : "需处理"} />
    </div>
  );
}

function FlowStep({ icon, label, detail, active = false }: { icon: ReactNode; label: string; detail: string; active?: boolean }) {
  return (
    <div className={`flow-step ${active ? "is-active" : ""}`}>
      <span className="flow-step-icon">{icon}</span>
      <strong>{label}</strong>
      <span>{detail}</span>
    </div>
  );
}

function SummaryItem({ label, value, icon }: { label: string; value: string; icon: ReactNode }) {
  return (
    <div className="summary-item">
      <span className="summary-item-icon">{icon}</span>
      <div>
        <span>{label}</span>
        <strong>{value}</strong>
      </div>
    </div>
  );
}
