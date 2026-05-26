import type { ReactNode } from "react";

type SectionPanelProps = {
  title: string;
  subtitle?: string;
  actions?: ReactNode;
  children: ReactNode;
};

export function SectionPanel({ title, subtitle, actions, children }: SectionPanelProps) {
  return (
    <section className="section-panel">
      <div className="section-heading">
        <div>
          <h2>{title}</h2>
          {subtitle ? <p>{subtitle}</p> : null}
        </div>
        {actions ? <div className="section-actions">{actions}</div> : null}
      </div>
      <div className="section-body">{children}</div>
    </section>
  );
}
