import { AlertTriangle, CheckCircle2, Clock3, Info, XCircle } from "lucide-react";

export type StatusTone = "success" | "warning" | "danger" | "info" | "neutral";

type StatusBadgeProps = {
  tone: StatusTone;
  label: string;
};

const iconByTone = {
  success: CheckCircle2,
  warning: AlertTriangle,
  danger: XCircle,
  info: Info,
  neutral: Clock3,
};

export function StatusBadge({ tone, label }: StatusBadgeProps) {
  const Icon = iconByTone[tone];
  return (
    <span className={`status-badge status-${tone}`}>
      <Icon size={13} />
      {label}
    </span>
  );
}
