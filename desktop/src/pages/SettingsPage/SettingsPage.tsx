import { Settings2 } from "lucide-react";
import { PageHeader } from "../../components/layout/PageHeader";
import { SectionPanel } from "../../components/layout/SectionPanel";

export function SettingsPage() {
  return (
    <div className="page-stack">
      <PageHeader eyebrow="全局" title="工作台偏好" description="只放置不属于字幕任务主流程的全局选项。" />
      <SectionPanel title="检查与交付偏好">
        <div className="object-list">
          <div className="object-row">
            <Settings2 size={18} />
            <div className="object-row-main">
              <strong>结果检查布局</strong>
              <span>默认打开字幕列表、当前行和质量状态。</span>
            </div>
          </div>
          <div className="object-row">
            <Settings2 size={18} />
            <div className="object-row-main">
              <strong>输出目录策略</strong>
              <span>使用任务输出目录，保留人工修改后的重新导出结果。</span>
            </div>
          </div>
        </div>
      </SectionPanel>
    </div>
  );
}
