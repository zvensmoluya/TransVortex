import { ExternalLink, FileText, RefreshCw } from "lucide-react";
import type { ExportedFile } from "../../domain/export";
import { StatusBadge, type StatusTone } from "../feedback/StatusBadge";
import { SectionPanel } from "../layout/SectionPanel";

type ExportFilesPanelProps = {
  files: ExportedFile[];
};

export function ExportFilesPanel({ files }: ExportFilesPanelProps) {
  return (
    <SectionPanel
      title="交付托盘"
      subtitle="SRT · ASS · VTT · 重新导出"
      actions={
        <button className="tvx-btn" type="button">
          <RefreshCw size={15} />
          重新导出
        </button>
      }
    >
      <div className="object-list">
        {files.length === 0 ? (
          <div className="empty-state">还没有可交付的字幕文件。</div>
        ) : (
          files.map((file) => (
            <div className={`object-row export-row is-${file.status}`} key={file.id}>
              <FileText size={18} />
              <div className="object-row-main">
                <strong>{file.format.toUpperCase()}</strong>
                <span>{file.path}</span>
              </div>
              <StatusBadge tone={exportTone(file.status)} label={exportLabel(file.status)} />
              <button className="icon-button" type="button" title="打开输出文件" aria-label="打开输出文件">
                <ExternalLink size={15} />
              </button>
            </div>
          ))
        )}
      </div>
    </SectionPanel>
  );
}

function exportTone(status: ExportedFile["status"]): StatusTone {
  if (status === "ready") return "success";
  if (status === "stale") return "warning";
  if (status === "failed") return "danger";
  return "neutral";
}

function exportLabel(status: ExportedFile["status"]): string {
  if (status === "ready") return "已导出";
  if (status === "stale") return "待重新导出";
  if (status === "failed") return "导出失败";
  return "未生成";
}
