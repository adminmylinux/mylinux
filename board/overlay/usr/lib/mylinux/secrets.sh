# Saved API keys (~/.config/mylinux/secrets.env, written by the Settings panel) as data, never as shell code.
# secrets_filter < FILE prints one validated KEY=value line per secret. Names: ^[A-Z][A-Z0-9_]{2,63}$; values
# are single lines and opaque (quotes, $, backticks stay literal). Older files wrote KEY='value' with '\'' for
# a quote; those are unwrapped. Consumers export the lines with `export "KEY=value"`, which does not evaluate.
secrets_filter() {
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}; val=${line#*=}
    case "$key" in ''|[!A-Z]*|*[!A-Z0-9_]*) continue ;; esac
    [ ${#key} -ge 3 ] && [ ${#key} -le 64 ] || continue
    case "$val" in \'*\') val=${val#\'}; val=${val%\'}; val=$(printf '%s' "$val" | sed "s/'\\\\''/'/g") ;; esac
    [ -n "$val" ] || continue
    printf '%s=%s\n' "$key" "$val"
  done
}
