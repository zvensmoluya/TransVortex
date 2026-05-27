import { ExternalLink, FileText, RefreshCw } from "lucide-react";
import type { DeliveryPresentation } from "../../adapters/taskPresentationAdapter";
import { StatusBadge } from "../feedback/StatusBadge";
import { SectionPanel } from "../layout/SectionPanel";

type ExportFilesPanelProps = {
  delivery: DeliveryPresentation;
  canReexport: boolean;
  onOpenFile?: (path: string) => void;
  onReexport?: () => void;
};

export function ExportFilesPanel({ delivery, canReexport, onOpenFile, onReexport }: ExportFilesPanelProps) {
  return (
    <SectionPanel
      title="交付托盘"
      subtitle={delivery.stateLabel}
      actions={
        <button className="tvx-btn" type="button" disabled={!canReexport || !onReexport} onClick={onReexport}>
          <RefreshCw size={15} />
          重新导出
        </button>
      }
    >
      <div className="object-list">
        {delivery.files.length === 0 ? (
          <div className="empty-state">{delivery.emptyLabel}</div>
        ) : (
          delivery.files.map((file) => (
            <div className={`object-row export-row is-${file.status}`} key={file.id}>
              <FileText size={18} />
              <div className="object-row-main">
                <strong>{file.displayName}</strong>
                <span>{file.path}</span>
              </div>
              <StatusBadge tone={file.statusTone} label={file.statusLabel} />
              <button
                className="icon-button"
                type="button"
                title="打开输出文件"
                aria-label="打开输出文件"
                disabled={!file.canOpen || !onOpenFile}
                onClick={() => onOpenFile?.(file.path)}
              >
                <ExternalLink size={15} />
              </button>
            </div>
          ))
        )}
      </div>
    </SectionPanel>
  );
}
