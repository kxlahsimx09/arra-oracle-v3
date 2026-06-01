import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, parse } from "node:path";

export const DEFAULT_ORACLE_API = "http://localhost:47778";

export type ArraConfig = { default?: string; targets?: Record<string, string> };
type LoadedConfig = { path: string; config: ArraConfig };
type Source = "ORACLE_API" | "at" | "project" | "global" | "NEO_ARRA_API" | "default";

export function normalizeApiBase(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

export function parseAtFlag(argv = process.argv.slice(2)): string | undefined {
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--at") return argv[i + 1];
    if (argv[i].startsWith("--at=")) return argv[i].slice(5);
  }
}

function readConfig(path: string): LoadedConfig | null {
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    const srcTargets = raw?.targets;
    if (!srcTargets || typeof srcTargets !== "object" || Array.isArray(srcTargets)) return null;
    const targets: Record<string, string> = {};
    for (const [name, url] of Object.entries(srcTargets)) {
      if (typeof url === "string" && url.trim()) targets[name] = normalizeApiBase(url);
    }
    return { path, config: { default: typeof raw.default === "string" ? raw.default : undefined, targets } };
  } catch {
    return null;
  }
}

function configPaths(dir: string): string[] {
  return [join(dir, "config.json"), join(dir, "targets.json")];
}

function firstConfig(paths: string[]): LoadedConfig | null {
  for (const path of paths) {
    const found = readConfig(path);
    if (found) return found;
  }
  return null;
}

function findProjectConfig(startDir = process.cwd()): LoadedConfig | null {
  let dir = startDir;
  const root = parse(dir).root;
  while (true) {
    const found = firstConfig(configPaths(join(dir, ".arra")));
    if (found || dir === root) return found;
    dir = dirname(dir);
  }
}

function globalConfigDir(env = process.env): string {
  const xdg = env.XDG_CONFIG_HOME?.trim();
  return xdg ? join(xdg, "arra") : join(env.HOME ?? homedir(), ".config", "arra");
}

export function globalConfigPathForWrite(env = process.env): string {
  return join(globalConfigDir(env), "config.json");
}

function findGlobalConfig(env = process.env): LoadedConfig | null {
  return firstConfig(configPaths(globalConfigDir(env)));
}

function targetFrom(loaded: LoadedConfig | null, name: string | undefined, source: Source) {
  if (!loaded || !name) return null;
  const baseUrl = loaded.config.targets?.[name];
  return baseUrl ? { baseUrl, source, target: name, path: loaded.path } : null;
}

function defaultFrom(loaded: LoadedConfig | null, source: "project" | "global") {
  return targetFrom(loaded, loaded?.config.default, source);
}

export function resolveOracleApi(argv = process.argv.slice(2), env = process.env) {
  if (env.ORACLE_API !== undefined) return { baseUrl: normalizeApiBase(env.ORACLE_API), source: "ORACLE_API" as const };

  const project = findProjectConfig();
  const global = findGlobalConfig(env);
  const atTarget = parseAtFlag(argv);
  const at = targetFrom(project, atTarget, "at") ?? targetFrom(global, atTarget, "at");
  if (at) return at;
  if (atTarget) throw new Error(`Unknown arra target '${atTarget}' in project/global config`);

  const projectDefault = defaultFrom(project, "project");
  if (projectDefault) return projectDefault;
  const globalDefault = defaultFrom(global, "global");
  if (globalDefault) return globalDefault;
  if (env.NEO_ARRA_API !== undefined) return { baseUrl: normalizeApiBase(env.NEO_ARRA_API), source: "NEO_ARRA_API" as const };
  return { baseUrl: DEFAULT_ORACLE_API, source: "default" as const };
}
