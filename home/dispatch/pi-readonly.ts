// Loaded by pi-worker --readonly. bash runs under a macOS sandbox-exec profile
// that denies file writes except temp dirs and CLI cache/credential state, and
// always denies writes under the working directory. The write tool may only
// touch the worker's answer file and its .done marker. Fails closed when the
// --readonly-out flag is missing.
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const quote = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;
const sbString = (s: string) => `"${s.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
const real = (p: string) => {
	try {
		return realpathSync(p);
	} catch {
		return join(realpathSync(dirname(resolve(p))), basename(p));
	}
};

function profile(cwd: string): string {
	const home = real(homedir());
	const writable = [
		"/private/tmp",
		"/private/var/folders",
		`${home}/Library/Caches`,
		`${home}/.cache`,
		`${home}/.local/share`,
		`${home}/.local/state`,
	];
	return [
		"(version 1)",
		"(allow default)",
		"(deny file-write*)",
		`(allow file-write* (regex #"^/dev/") ${writable.map((p) => `(subpath ${sbString(p)})`).join(" ")})`,
		`(deny file-write* (subpath ${sbString(real(cwd))}))`,
	].join("");
}

export default function (pi: ExtensionAPI) {
	pi.registerFlag("readonly-out", { description: "Only file the write tool may write (plus .done)", type: "string" });

	pi.on("tool_call", async (event, ctx) => {
		const out = pi.getFlag("readonly-out");
		if (typeof out !== "string" || out === "") return { block: true, reason: "read-only worker misconfigured" };
		if (event.toolName === "bash") {
			const command = event.input.command as string;
			event.input.command = `sandbox-exec -p ${quote(profile(ctx.cwd))} /bin/bash -c ${quote(command)}`;
			return undefined;
		}
		if (event.toolName === "write" || event.toolName === "edit") {
			const target = real(resolve(ctx.cwd, event.input.path as string));
			const allowed = [real(out), `${real(out)}.done`];
			if (!allowed.includes(target)) return { block: true, reason: `read-only worker: writes are limited to ${out}` };
		}
		return undefined;
	});
}
