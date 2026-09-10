# Sourced by interactive shells ($ENV) and login shells: API keys saved by the Settings panel, exported as
# data (no shell evaluation of the file; see /usr/lib/mylinux/secrets.sh).
if [ -f /root/.config/mylinux/secrets.env ]; then
  . /usr/lib/mylinux/secrets.sh
  while IFS= read -r _l; do [ -n "$_l" ] && export "$_l"; done <<EOF_SECRETS
$(secrets_filter < /root/.config/mylinux/secrets.env)
EOF_SECRETS
  unset _l
fi
