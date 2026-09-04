usage() {
	cat <<'EOF'
Usage: dcf [LANG] [PATH]

Report unused code and dependencies. Never modifies files.

LANG  nix | python | js | go | rust (default: detect from PATH contents)
PATH  directory to scan (default: .)

A non-zero exit status from an analyzer usually means findings, not failure.
EOF
}

lang=all

case "${1-}" in
	-h | --help)
		usage
		exit 0
		;;
	nix | python | js | go | rust)
		lang=$1
		shift
		;;
esac

target=${1-.}

if [ ! -d "$target" ]; then
	echo "dcf: not a directory: $target" >&2
	exit 1
fi

cd "$target"

ran=0

run() {
	local label=$1
	shift
	local status=0
	printf '\n== %s ==\n' "$label"
	"$@" || status=$?
	if [ "$status" -ne 0 ]; then
		printf 'dcf: %s exit status %d\n' "$label" "$status"
	fi
	ran=1
}

# staticcheck and cargo-shear shell out to the project toolchain, which is not bundled
require() {
	if ! command -v "$1" >/dev/null; then
		printf '\n== %s ==\ndcf: %s not found in PATH; skipped\n' "$2" "$1"
		ran=1
		return 1
	fi
}

# Inside a Git work tree the scan follows .gitignore, so build outputs stay out.
# An ignored target is scanned directly, or it would list nothing.
git_listable() {
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 && ! git check-ignore -q .
}

list_files() {
	if git_listable; then
		git ls-files --cached --others --exclude-standard -z -- "$1"
	else
		find . -name "$1" -not -path './.git/*' -print0
	fi
}

has_files() {
	local first=""
	IFS= read -r -d '' first < <(list_files "$1") || true
	[ -n "$first" ]
}

run_files() {
	local label=$1 glob=$2
	shift 2
	local files=() file
	while IFS= read -r -d '' file; do files+=("$file"); done < <(list_files "$glob")
	if [ "${#files[@]}" -eq 0 ]; then
		printf '\n== %s ==\ndcf: no %s files to scan\n' "$label" "$glob"
		ran=1
		return
	fi
	run "$label" "$@" "${files[@]}"
}

has_nix() { has_files '*.nix'; }
has_python() { [ -f pyproject.toml ] || has_files '*.py'; }
has_js() { [ -f package.json ]; }
has_go() { [ -f go.mod ]; }
has_rust() { [ -f Cargo.toml ]; }

wanted() {
	case $lang in
		all) "has_$1" ;;
		"$1") true ;;
		*) false ;;
	esac
}

if wanted nix; then
	run_files deadnix '*.nix' deadnix
fi

if wanted python; then
	run_files vulture '*.py' vulture
	if [ -f pyproject.toml ]; then
		run deptry deptry .
	fi
fi

if wanted js; then
	run knip knip
fi

if wanted go; then
	if require go staticcheck; then
		run staticcheck staticcheck -checks U1000 ./...
	fi
fi

if wanted rust; then
	if require cargo cargo-shear; then
		run cargo-shear cargo-shear
	fi
fi

if [ "$ran" -eq 0 ]; then
	echo "dcf: no supported project detected in $PWD" >&2
	exit 1
fi
