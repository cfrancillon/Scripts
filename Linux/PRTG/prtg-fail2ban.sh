#!/bin/bash
JAIL="apache-scan"

BANNED=$(sudo /usr/bin/fail2ban-client status "$JAIL" 2>/dev/null \
         | sed -n 's/.*Currently banned:[[:space:]]*//p' | tr -dc '0-9')

if [ -z "$BANNED" ]; then
  echo "<prtg><error>1</error><text>Jail $JAIL indisponible</text></prtg>"
  exit 0
fi

echo "<prtg><result><channel>IP bannies</channel><value>${BANNED}</value><unit>Count</unit><limitmaxwarning>4</limitmaxwarning><limitmaxerror>8</limitmaxerror><limitmode>1</limitmode></result></prtg>"