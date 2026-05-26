import { Circle, CircleCheck, CircleDot, CircleX } from "lucide-react";
import type { TaskPipelineStep } from "../../domain/taskRun";

type PipelineBarProps = {
  steps: TaskPipelineStep[];
};

export function PipelineBar({ steps }: PipelineBarProps) {
  return (
    <ol className="pipeline-bar">
      {steps.map((step) => {
        const Icon = iconForStep(step.status);
        return (
          <li key={step.id} className={`pipeline-step is-${step.status}`}>
            <Icon size={15} />
            <span>{step.label}</span>
          </li>
        );
      })}
    </ol>
  );
}

function iconForStep(status: TaskPipelineStep["status"]) {
  if (status === "completed") return CircleCheck;
  if (status === "active") return CircleDot;
  if (status === "failed") return CircleX;
  return Circle;
}
