import json, os, sys, tomlkit

target: str
fragment: str
statefile: str
target, fragment, statefile = sys.argv[1], sys.argv[2], sys.argv[3]


def read(p: str) -> str:
    if os.path.exists(p):
        with open(p) as f:
            return f.read()
    return ""


def write_atomic(path: str, text: str) -> None:
    tmp = path + ".hm-tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


text = read(target)
try:
    doc = tomlkit.parse(text) if text.strip() else tomlkit.document()
except tomlkit.exceptions.ParseError as e:
    # don't brick `switch` on a GUI/hand-broken config.toml; skip and warn
    print(f"codexMcpMerge: skipping, {target} is not valid TOML: {e}", file=sys.stderr)
    sys.exit(0)

new_servers = tomlkit.parse(read(fragment)).get("mcp_servers", {})
prev: list[str] = json.loads(read(statefile) or "[]")

servers = doc.get("mcp_servers")
if servers is None:
    servers = tomlkit.table()
    doc["mcp_servers"] = servers

# remove only nix-owned servers so GUI-added ones (not in prev) survive
for name in prev:
    if name in servers:
        del servers[name]

# nix wins on name collision
for name, val in new_servers.items():
    servers[name] = val

write_atomic(target, tomlkit.dumps(doc))
write_atomic(statefile, json.dumps(list(new_servers.keys())))
