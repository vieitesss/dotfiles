/**
 * Blocks bash calls that sleep while a pi-background-tasks job is running
 * with automatic wake-up. The job's terminal notification starts a new turn,
 * so the agent should end its turn and wait idle instead of sleeping or
 * polling. The package's own prompt guidelines say this; models ignore them.
 *
 * Running tasks come from the package's EventBus `status` operation. If the
 * package does not answer (not installed, not initialized), the call is
 * allowed.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const requestChannel = "pi-background-tasks:request:v1";
const responseChannel = "pi-background-tasks:response:v1";
const statusTimeoutMs = 1000;

type Task = { name: string; status: string; notifyOnCompletion: boolean; triggerOnCompletion: boolean };

// sleep in command position: line start, after ; & | ( ` or $(, or after
// do/then/else, as a bare name or a path.
const startsSleep = /(^|[;&|(`]|\$\(|\b(do|then|else)\s)\s*(exec\s+)?(\S*\/)?sleep(?=\s|$)/m;

/** True when the command runs `sleep` (quoted strings are data, not commands). */
export function sleeps(command: string): boolean {
	return startsSleep.test(command.replace(/'(?:[^']*)'|"(?:[^"\\]|\\.)*"/g, " "));
}

export default function (pi: ExtensionAPI) {
	function wakingTasks(): Promise<Task[]> {
		return new Promise((resolve) => {
			const requestId = `bg-no-sleep-${crypto.randomUUID()}`;
			const done = (tasks: Task[]) => {
				clearTimeout(timer);
				off();
				resolve(tasks);
			};
			const timer = setTimeout(() => done([]), statusTimeoutMs);
			const off = pi.events.on(responseChannel, (frame: any) => {
				if (frame?.request_id !== requestId) return;
				const tasks: Task[] = frame.ok ? (frame.result?.tasks ?? []) : [];
				done(tasks.filter((t) => t.status === "running" && t.notifyOnCompletion && t.triggerOnCompletion));
			});
			pi.events.emit(requestChannel, {
				schema_version: "pi-background-tasks.extension-request.v1",
				request_id: requestId,
				operation: "status",
				payload: {},
			});
		});
	}

	pi.on("tool_call", async (event) => {
		if (event.toolName !== "bash") return;
		const command = (event.input as { command?: unknown }).command;
		if (typeof command !== "string" || !sleeps(command)) return;
		const tasks = await wakingTasks();
		if (tasks.length === 0) return;
		const names = tasks.map((t) => `"${t.name}"`).join(", ");
		return {
			block: true,
			reason:
				`Blocked: do not sleep while background task(s) ${names} are running. ` +
				"Their <background-task-notification> starts a new turn when they finish. " +
				"Do any independent work, otherwise end your turn now and wait idle. " +
				"Do not poll with bg_status or bg_logs either.",
		};
	});
}
