#!/bin/bash
# prtg-cpu.sh - Usage CPU pour PRTG (capteur "SSH Script Advanced")
# Depend de sysstat (mpstat). Aucun privilege root necessaire.
export LC_ALL=C

if ! command -v mpstat >/dev/null 2>&1; then
  echo "<prtg><error>1</error><text>mpstat introuvable - installer le paquet sysstat</text></prtg>"
  exit 0
fi

# Echantillon de 1s, parsing par nom de colonne (robuste aux versions de mpstat)
read -r USR SYS IOW IDLE < <(
  mpstat 1 1 | awk '
    /%idle/    { for (i=1;i<=NF;i++) c[$i]=i; next }
    /^Average/ { print $(c["%usr"]), $(c["%sys"]), $(c["%iowait"]), $(c["%idle"]) }
  '
)

if [ -z "$IDLE" ]; then
  echo "<prtg><error>1</error><text>Parsing mpstat echoue</text></prtg>"
  exit 0
fi

TOTAL=$(awk -v i="$IDLE" 'BEGIN { printf "%.1f", 100 - i }')

cat <<EOF
<prtg>
  <result>
    <channel>CPU total</channel>
    <value>${TOTAL}</value>
    <unit>Percent</unit>
    <float>1</float>
    <limitmaxwarning>60</limitmaxwarning>
    <limitmaxerror>90</limitmaxerror>
    <limitmode>1</limitmode>
  </result>
  <result>
    <channel>Utilisateur</channel>
    <value>${USR}</value>
    <unit>Percent</unit>
    <float>1</float>
  </result>
  <result>
    <channel>Systeme</channel>
    <value>${SYS}</value>
    <unit>Percent</unit>
    <float>1</float>
  </result>
  <result>
    <channel>IO wait</channel>
    <value>${IOW}</value>
    <unit>Percent</unit>
    <float>1</float>
  </result>
</prtg>
EOF