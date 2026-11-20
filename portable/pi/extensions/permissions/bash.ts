import { execFile } from "node:child_process";

export interface ShellAnalysis {
  commands: (string | null)[][];
  files: { path: string; access: "read" | "write" }[];
  uncertain: string[];
  stdinGreps?: number[];
  steps?: ShellStep[];
}

export interface ShellStep {
  args: string[];
  operator: ";" | "&&" | "||" | "|";
  files: ShellAnalysis["files"];
  unresolved?: ShellAnalysis;
  redirectedStdin?: boolean;
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

function inspectCommands(tree: Node): ShellAnalysis {
  const result: ShellAnalysis = { commands: [], files: [], uncertain: [] };
  const pipeInputs = new WeakSet<Node>();
  const opaque =
    /^(?:eval|source|\.|exec|bash|sh|zsh|fish|python\d*(?:\.\d+)?|node|ruby|perl|awk|gawk|xargs|find|env|sudo|command|builtin|cd|pushd|popd)$/;

  function walk(node: unknown): void {
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    if (!node || typeof node !== "object") return;
    const value = node as Node;
    if (
      value.Type === "BinaryCmd" &&
      value.Op === "|" &&
      value.Y?.Cmd?.Type === "CallExpr" &&
      !value.Y.Redirs?.length
    ) {
      pipeInputs.add(value.Y.Cmd);
    }
    if (value.Type === "CallExpr") {
      const args = (value.Args ?? []).map((word: Node) => literal(word));
      if (pipeInputs.has(value) && !value.Assigns?.length && stdinGrep(args)) {
        (result.stdinGreps ??= []).push(result.commands.length);
      }
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

export function inspectAst(tree: Node): ShellAnalysis {
  const result = inspectCommands(tree);
  if (Array.isArray(tree.Stmts)) {
    const steps: ShellStep[] = [];
    for (const stmt of tree.Stmts) collectStep(stmt, ";", steps);
    result.steps = steps;
  }
  return result;
}

function stdinGrep(args: (string | null)[]): boolean {
  const pattern = args.at(-1);
  return (
    args[0] === "grep" &&
    args.length >= 2 &&
    typeof pattern === "string" &&
    !pattern.startsWith("-") &&
    args.slice(1, -1).every((arg) => arg !== null && /^-[EFiv]+$/.test(arg))
  );
}

function collectStep(
  stmt: Node,
  operator: ShellStep["operator"],
  steps: ShellStep[],
): void {
  const unresolved = () => {
    steps.push({
      args: [],
      files: [],
      operator,
      unresolved: inspectCommands(stmt),
    });
  };
  if (stmt.Background || stmt.Negated || stmt.Coprocess || stmt.Disown)
    return unresolved();
  const cmd = stmt.Cmd;
  if (
    cmd?.Type === "BinaryCmd" &&
    !stmt.Redirs?.length &&
    ["&&", "||", "|"].includes(cmd.Op)
  ) {
    collectStep(cmd.X, operator, steps);
    collectStep(cmd.Y, cmd.Op, steps);
    return;
  }
  if (cmd?.Type !== "CallExpr" || cmd.Assigns?.length) return unresolved();
  const args: (string | null)[] = (cmd.Args ?? []).map((word: Node) =>
    literal(word),
  );
  if (!args.length || !args.every((arg): arg is string => arg !== null))
    return unresolved();
  if (["env", "sudo", "command", "builtin", "exec"].includes(args[0]))
    return unresolved();
  const files: ShellStep["files"] = [];
  let redirectedStdin = false;
  for (const redirect of stmt.Redirs ?? []) {
    const path = literal(redirect.Word ?? {});
    if (
      path === null ||
      !["<", ">", ">>", ">|", "&>", "&>>", "<>"].includes(redirect.Op)
    )
      return unresolved();
    if (redirect.Op === "<" && (!redirect.N || redirect.N.Value === "0"))
      redirectedStdin = true;
    files.push({ path, access: redirect.Op === "<" ? "read" : "write" });
  }
  steps.push({ args, operator, files, redirectedStdin });
}

export interface CommandOperands {
  paths: string[];
  kind?: "directory" | "tree" | "archive";
  outputs?: string[];
}

export function commandOperands(
  [name, ...args]: string[],
  stdin: boolean,
): CommandOperands | undefined {
  const data = { paths: [] };
  if (name === "echo") return data;
  if (
    name === "cd" &&
    args.length === 1 &&
    args[0] &&
    !args[0].startsWith("-") &&
    (!process.env.CDPATH || /^(?:\/|\.\.?\/|\.$)/.test(args[0]))
  )
    return { paths: args };
  if (
    name === "unzip" &&
    args[0] === "-l" &&
    args.length === 2 &&
    !args[1].startsWith("-")
  )
    return { paths: [args[1]], kind: "archive" };
  if (["ls", "du", "file", "stat", "cat", "wc"].includes(name)) {
    const flags: Record<string, RegExp> = {
      ls: /^-[alh]+$/,
      du: /^-[shk]+$/,
      file: /^-[bi]+$/,
      stat: /^-x$/,
      cat: /^-[nbs]+$/,
      wc: /^-[lcwm]+$/,
    };
    const paths = args.filter((arg) => !flags[name].test(arg));
    if (paths.some((arg) => arg.startsWith("-"))) return;
    if (name === "ls" || name === "du")
      return {
        paths: paths.length ? paths : ["."],
        kind: name === "du" ? "tree" : "directory",
      };
    if (paths.length || stdin) return { paths };
  }
  if (name === "grep" || name === "rg") {
    if (name === "rg" && process.env.RIPGREP_CONFIG_PATH) return;
    let i = 0;
    const flags = name === "rg" ? /^-[Fivcon]+$/ : /^-[EFivconr]+$/;
    let recursive = false;
    while (
      i < args.length &&
      (flags.test(args[i]) || (name === "grep" && args[i] === "--recursive"))
    ) {
      recursive ||= args[i].includes("r");
      i++;
    }
    const paths: string[] = [];
    if (args[i] === "-f" && args[i + 1]) {
      paths.push(args[i + 1]);
      i += 2;
    } else if (i < args.length && !args[i].startsWith("-")) i++;
    else return;
    if (!stdin && i === args.length && name === "grep" && !recursive) return;
    if (args.slice(i).some((arg) => arg.startsWith("-"))) return;
    const targets = args.slice(i);
    if (!targets.length && (recursive || (!stdin && name === "rg")))
      targets.push(".");
    return {
      paths: [...paths, ...targets],
      kind: recursive || name === "rg" ? "tree" : undefined,
    };
  }
  if (name === "head" || name === "tail") {
    const paths = [...args];
    if (/^-\d+$/.test(paths[0])) paths.shift();
    else if (paths[0] === "-n" && /^\d+$/.test(paths[1])) paths.splice(0, 2);
    if ((paths.length || stdin) && paths.every((arg) => !arg.startsWith("-")))
      return { paths };
  }
  if (name === "sort") {
    const paths: string[] = [];
    const outputs: string[] = [];
    for (let i = 0; i < args.length; i++) {
      const arg = args[i];
      if (/^-[nru]+$/.test(arg)) continue;
      if (arg === "-o" || arg === "--output") {
        if (!args[i + 1]) return;
        outputs.push(args[++i]);
      } else if (arg.startsWith("--output=")) outputs.push(arg.slice(9));
      else if (arg.startsWith("-o")) outputs.push(arg.slice(2));
      else if (arg.startsWith("-")) return;
      else paths.push(arg);
    }
    if (paths.length || stdin) return { paths, outputs };
  }
  if (name === "uniq") {
    const operands = args.filter((arg) => arg !== "-c");
    if (
      operands.length > 2 ||
      operands.some((arg) => arg !== "-" && arg.startsWith("-"))
    )
      return;
    const [input, output] = operands;
    if (input || stdin)
      return {
        paths: input && input !== "-" ? [input] : [],
        outputs: output && output !== "-" ? [output] : [],
      };
  }
  if (!stdin) return;
  if (
    name === "cut" &&
    args.some((arg) => /^-f\d/.test(arg)) &&
    args.every((arg) => /^-d.$/.test(arg) || /^-f\d+(?:-\d+)?$/.test(arg))
  )
    return data;
  if (
    name === "awk" &&
    args.length === 1 &&
    /^\{\s*print\s+\$(?:\d+|NF)\s*\}$/.test(args[0])
  )
    return data;
  if (
    name === "sed" &&
    args.length === 1 &&
    /^s\/(?:\\[./]|[^/\\\r\n])+\/(?:\\[./]|[^/\\\r\n])*\/g?$/.test(args[0])
  )
    return data;
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
