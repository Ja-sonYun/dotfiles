import { execFile } from "node:child_process";

export interface ShellAnalysis {
  commands: (string | null)[][];
  files: { path: string; access: "read" | "write" }[];
  uncertain: string[];
}

type Node = Record<string, any>;

function literal(word: Node, quoted = false): string | null {
  if (!Array.isArray(word.Parts)) return null;
  const parts = word.Parts.map((part: Node): string | null => {
    if (part.Type === "SglQuoted" && !part.Dollar) return part.Value;
    if (part.Type === "DblQuoted" && !part.Dollar) return literal(part, true);
    if (part.Type !== "Lit") return null;
    if (/\\/.test(part.Value) || (!quoted && /[*?\[\]{}~]/.test(part.Value)))
      return null;
    return part.Value;
  });
  return parts.includes(null) ? null : parts.join("");
}

export function inspectAst(tree: Node): ShellAnalysis {
  const result: ShellAnalysis = { commands: [], files: [], uncertain: [] };
  const opaque =
    /^(?:eval|source|\.|exec|bash|sh|zsh|fish|python\d*(?:\.\d+)?|node|ruby|perl|awk|gawk|xargs|find|env|sudo|command|builtin|cd|pushd|popd)$/;

  function walk(node: unknown): void {
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    if (!node || typeof node !== "object") return;
    const value = node as Node;
    if (value.Type === "CallExpr") {
      const args = (value.Args ?? []).map((word: Node) => literal(word));
      if (args.length) result.commands.push(args);
      if (args.includes(null) || value.Assigns?.length) {
        result.uncertain.push("Shell expansion or environment assignment");
      }
      if (
        typeof args[0] === "string" &&
        (opaque.test(args[0].slice(args[0].lastIndexOf("/") + 1)) ||
          args[0].includes("/"))
      ) {
        result.uncertain.push(
          `Indirect execution or changed shell context: ${args[0]}`,
        );
      }
      if (["env", "sudo", "command", "builtin", "exec"].includes(args[0])) {
        const inner = args.slice(1);
        while (
          typeof inner[0] === "string" &&
          /^[A-Za-z_][A-Za-z0-9_]*=/.test(inner[0])
        )
          inner.shift();
        if (inner.length && !inner[0]?.startsWith("-"))
          result.commands.push(inner);
      }
      if (args[0] === "tee") {
        for (const arg of args.slice(1)) {
          if (typeof arg === "string" && !arg.startsWith("-"))
            result.files.push({ path: arg, access: "write" });
        }
      }
    }
    if (Array.isArray(value.Redirs)) {
      for (const redirect of value.Redirs) {
        const target = literal(redirect.Word ?? {});
        if (
          target !== null &&
          ["<", ">", ">>", ">|", "&>", "&>>", "<>"].includes(redirect.Op)
        ) {
          result.files.push({
            path: target,
            access: redirect.Op === "<" ? "read" : "write",
          });
        } else {
          result.uncertain.push(
            "Dynamic redirection, descriptor duplication, or here document",
          );
        }
      }
    }
    if (
      [
        "FuncDecl",
        "ForClause",
        "WhileClause",
        "CaseClause",
        "DeclClause",
        "ArithmCmd",
        "TestClause",
        "CmdSubst",
        "ProcSubst",
      ].includes(value.Type)
    ) {
      result.uncertain.push(`Shell construct: ${value.Type}`);
    }
    Object.values(value).forEach(walk);
  }

  walk(tree);
  result.uncertain = [...new Set(result.uncertain)];
  return result;
}

export async function analyzeBash(
  command: string,
  parser: string,
): Promise<ShellAnalysis> {
  return new Promise((resolve) => {
    const child = execFile(
      parser,
      ["-ln", "bash", "--to-json"],
      { timeout: 5000, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout) => {
        try {
          if (error) throw error;
          resolve(inspectAst(JSON.parse(stdout)));
        } catch {
          resolve({
            commands: [],
            files: [],
            uncertain: [
              "Bash could not be parsed; inspect the complete original command",
            ],
          });
        }
      },
    );
    child.stdin?.on("error", () => {});
    child.stdin?.end(command);
  });
}
