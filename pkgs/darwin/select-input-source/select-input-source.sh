abc_source="com.apple.keylayout.ABC"
korean_source="com.apple.inputmethod.Korean.2SetKorean"
japanese_source="com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"

if [ "$#" -ne 1 ]; then
	printf 'usage: select-input-source SOURCE_ID\n' >&2
	exit 2
fi

target_source="$1"
case "$target_source" in
	"$abc_source" | "$korean_source" | "$japanese_source") ;;
	*)
		printf 'unsupported target input source: %s\n' "$target_source" >&2
		exit 2
		;;
esac

current_source="$(macism)"
case "$current_source:$target_source" in
	"$abc_source:$abc_source" | "$korean_source:$korean_source" | "$japanese_source:$japanese_source")
		exit 0
		;;
	"$abc_source:$japanese_source" | "$japanese_source:$korean_source" | "$korean_source:$abc_source")
		presses=1
		;;
	"$abc_source:$korean_source" | "$japanese_source:$abc_source" | "$korean_source:$japanese_source")
		presses=2
		;;
	*)
		printf 'unsupported current input source: %s\n' "$current_source" >&2
		exit 1
		;;
esac

while [ "$presses" -gt 0 ]; do
	skhd -k "ctrl + alt - space"
	presses=$((presses - 1))
	if [ "$presses" -gt 0 ]; then
		/bin/sleep 0.08
	fi
done
