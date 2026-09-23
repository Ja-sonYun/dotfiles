def short: . as $p | (env.HOME // "") as $h
  | if $h != "" and ($p | startswith($h)) then "~" + $p[($h | length):] else $p end;

[ "\(.context_window.remaining_percentage // 100)% context left",
  (.workspace.current_dir // .cwd // "" | short),
  ([.model.display_name, .effort.level]
    | map(select(. != null and . != "")) | join(" "))
]
| join("   ")
