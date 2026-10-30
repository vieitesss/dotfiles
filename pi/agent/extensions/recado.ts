// recado-shim: "4"
/**
 * recado's Pi extension: turns recado messages into user turns and reports the
 * session and turn lifecycle to `recado hook pi ...`.
 *
 * Installed by "recado skill setup"; remove it with "recado skill remove".
 */
import { execFile, type ExecFileException } from "node:child_process";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// hookTimeout bounds one call to recado. A hook runs on Pi's event loop, the
// thread the human types on, so a wedged CLI would freeze the session; a call
// that runs out counts as a failed hook, which the session is told about and
// which hands no message over.
const hookTimeout = 5_000;

// stateDir mirrors recado's state root: $RECADO_STATE_DIR, else XDG state.
function stateDir(): string {
	if (process.env.RECADO_STATE_DIR) return process.env.RECADO_STATE_DIR;
	const base = process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local", "state");
	return path.join(base, "recado");
}

// ownedDir creates a directory recado owns and keeps it at 0700: Node ignores
// the mode of a directory that already exists, so the mode is set again after
// the mkdir.
function ownedDir(dir: string): void {
	fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	fs.chmodSync(dir, 0o700);
}

// launcherAddr is RECADO_ADDR as the launcher set it, before this extension
// writes a session id. Shutdown restores it before /reload reevaluates the
// extension, so a derived id never becomes a launcher override.
const launcherAddr = process.env.RECADO_ADDR;

// agentID is the launcher's RECADO_ADDR when it set one, else the session id
// lowercased into recado's id charset.
function agentID(ctx: ExtensionContext): string {
	if (launcherAddr) return launcherAddr.slice(launcherAddr.lastIndexOf("/") + 1);
	const raw = ctx.sessionManager.getSessionId() || `pi-${process.pid}`;
	const id = raw.toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^[^a-z0-9]+/, "");
	return id || `pi-${process.pid}`;
}

// hookFailure says why a call to recado failed, for the notice the human reads.
function hookFailure(err: ExecFileException, stderr: string): string {
	if (err.code === "ENOENT") return "recado is not on PATH";
	if (err.killed) return `recado did not answer within ${hookTimeout}ms`;
	return stderr.trim() || err.message;
}

// hook runs one recado hook and returns the messages recado could not push
// itself. It rejects with the reason when the hook failed or its answer is
// unusable.
function hook(event: string, sock?: string): Promise<string[]> {
	const args = ["hook", "pi", event, "--json"];
	if (sock) args.push("--endpoint", sock);
	// The child may push a backlog to this very socket while draining. Keep
	// the event loop free to acknowledge it before the child can exit.
	return new Promise((resolve, reject) => {
		execFile("recado", args, { encoding: "utf8", timeout: hookTimeout }, (err, stdout, stderr) => {
			if (err) return reject(new Error(hookFailure(err, stderr)));
			try {
				resolve((JSON.parse(stdout).pending ?? []).map((msg: { text: string }) => msg.text));
			} catch (parseErr) {
				reject(new Error(`recado gave an unusable response: ${parseErr}`));
			}
		});
	});
}

// waiting is one message waiting for the session: its text, and the answer
// recado is waiting on when recado pushed it over the socket.
type waiting = { text: string; reply?: (ok: boolean, err?: string) => void };

export default function (pi: ExtensionAPI) {
	let sock = "";
	let server: net.Server | undefined;
	let running = false;
	const queued: waiting[] = [];

	// flush refuses when Pi is busy outside a run (such as manual compaction)
	// or has no usable model. Pi's extension API returns void and swallows
	// asynchronous errors, so it cannot confirm admission beyond these checks.
	// Refused pushes return to recado's store; messages a hook handed over have
	// no owner to return to and stay queued for the next event.
	function flush(ctx: ExtensionContext) {
		while (queued.length > 0) {
			const msg = queued[0];
			try {
				const idle = ctx.isIdle();
				if (!idle && !running) throw new Error("the session is busy outside a turn");
				if (idle && !ctx.model) throw new Error("the session has no model");
				if (idle && ctx.model && typeof ctx.modelRegistry.hasConfiguredAuth === "function" &&
					!ctx.modelRegistry.hasConfiguredAuth(ctx.model)) throw new Error("the session has no configured model authentication");
				pi.sendUserMessage(msg.text, { deliverAs: "steer" });
			} catch (err) {
				const reason = String(err);
				const refused = queued.splice(0);
				queued.push(...refused.filter((msg) => !msg.reply));
				for (const msg of refused) msg.reply?.(false, reason);
				return;
			}
			queued.shift();
			msg.reply?.(true);
		}
	}

	// report runs a hook and queues whatever the shim must deliver itself.
	async function report(ctx: ExtensionContext, event: string, endpoint?: string) {
		try {
			const pending = await hook(event, endpoint);
			queued.push(...pending.map((text) => ({ text })));
		} catch (err) {
			ctx.ui.notify(`recado: hook ${event} failed: ${(err as Error).message}`, "error");
		}
		flush(ctx);
	}

	pi.on("session_start", async (_event, ctx) => {
		process.env.RECADO_ADDR = agentID(ctx);
		process.env.RECADO_HARNESS = "pi";
		const dir = path.join(stateDir(), "run");
		try {
			ownedDir(dir);
		} catch (err) {
			ctx.ui.notify(`recado: cannot keep ${dir} at 0700: ${err}`, "error");
		}
		sock = path.join(dir, `pi-${process.pid}.sock`);
		try {
			fs.unlinkSync(sock);
		} catch {}
		server = net.createServer((conn) => {
			conn.on("error", () => {});
			let buf = "";
			conn.on("data", (chunk) => {
				buf += chunk.toString("utf8");
				let nl: number;
				while ((nl = buf.indexOf("\n")) >= 0) {
					const line = buf.slice(0, nl);
					buf = buf.slice(nl + 1);
					if (!line.trim()) continue;
					let text: unknown;
					try {
						text = JSON.parse(line).text;
					} catch {
						text = undefined;
					}
					if (typeof text !== "string") {
						conn.end(JSON.stringify({ ok: false, error: "not a recado message" }) + "\n");
						continue;
					}
					queued.push({
						text,
						reply: (ok, err) =>
							conn.end(JSON.stringify(ok ? { ok: true } : { ok: false, error: err ?? "refused" }) + "\n"),
					});
				}
				flush(ctx);
			});
		});
		try {
			await new Promise<void>((resolve, reject) => {
				server!.on("error", reject);
				server!.listen(sock, resolve);
			});
			fs.chmodSync(sock, 0o600);
		} catch (err) {
			ctx.ui.notify(`recado: cannot listen on ${sock}: ${err}`, "error");
			return;
		}
		await report(ctx, "session-start", sock);
	});

	pi.on("agent_start", (_event, ctx) => {
		running = true;
		return report(ctx, "turn-start");
	});
	pi.on("agent_end", async (_event, ctx) => {
		try {
			await report(ctx, "turn-end");
		} finally {
			running = false;
		}
	});

	pi.on("session_shutdown", () => {
		if (launcherAddr === undefined) delete process.env.RECADO_ADDR;
		else process.env.RECADO_ADDR = launcherAddr;
		server?.close();
		server = undefined;
		try {
			fs.unlinkSync(sock);
		} catch {}
	});
}
