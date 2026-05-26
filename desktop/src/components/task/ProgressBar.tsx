type ProgressBarProps = {
  value: number;
  label: string;
  compact?: boolean;
};

export function ProgressBar({ value, label, compact = false }: ProgressBarProps) {
  const boundedValue = Math.max(0, Math.min(100, value));

  return (
    <div className={`progress-meter ${compact ? "is-compact" : ""}`}>
      <div className="progress-label">
        <span>{label}</span>
        <strong>{boundedValue}%</strong>
      </div>
      <div className="progress-track" aria-hidden="true">
        <div className="progress-fill" style={{ width: `${boundedValue}%` }} />
      </div>
    </div>
  );
}
