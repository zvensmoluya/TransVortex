import { Wrench } from "lucide-react";
import type { EnvironmentCheck } from "../../domain/environment";
import { StatusBadge, type StatusTone } from "../feedback/StatusBadge";

type EnvironmentCheckListProps = {
  checks: EnvironmentCheck[];
};

export function EnvironmentCheckList({ checks }: EnvironmentCheckListProps) {
  return (
    <div className="diagnostics-list">
      {checks.map((check) => (
        <article className="diagnostic-row" key={check.id}>
          <Wrench size={18} />
          <div className="diagnostic-main">
            <div className="diagnostic-title">
              <strong>{check.label}</strong>
              <StatusBadge tone={checkTone(check.status)} label={checkLabel(check.status)} />
            </div>
            <p>{check.impact}</p>
          </div>
          <div className="diagnostic-actions">
            {check.nextActions.map((action) => (
              <button className="tvx-btn tvx-btn-quiet" type="button" key={action.id}>
                {action.label}
              </button>
            ))}
          </div>
        </article>
      ))}
    </div>
  );
}

function checkTone(status: EnvironmentCheck["status"]): StatusTone {
  if (status === "pass") return "success";
  if (status === "warn") return "warning";
  return "danger";
}

function checkLabel(status: EnvironmentCheck["status"]): string {
  if (status === "pass") return "通过";
  if (status === "warn") return "需注意";
  return "阻塞";
}
