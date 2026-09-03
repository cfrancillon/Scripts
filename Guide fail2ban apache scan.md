# Guide de déploiement — Détection de scans Apache (fail2ban) + supervision PRTG

Ce guide reprend, étape par étape, la mise en place complète de la solution :
détecter les scanners de vulnérabilités qui frappent un serveur Apache, les
bannir automatiquement, escalader les sanctions contre les récidivistes, et
**superviser le tout depuis PRTG** (nombre d'IP bannies remonté par un capteur
SSH, seuils et notifications gérés centralement).

Il est conçu pour être **rejoué facilement sur d'autres serveurs** : seules
quelques variables (chemin des logs, réseau interne, compte PRTG, seuils) sont à
adapter. Elles sont regroupées dans la section « Variables à adapter par
serveur » plus bas.

> **Contexte technique** : Debian/Ubuntu, Apache journalisant au format `common`
> (pas de User-Agent dans les logs), accès `root`, un serveur PRTG déjà en place
> qui interroge les serveurs Linux en SSH. Le filtre fail2ban est bâti sur le
> **taux d'erreurs 4xx**, indicateur fiable d'un scan qui déroule une wordlist,
> et non sur le User-Agent.

> **Convention de nommage des logs de ce guide** : les vhosts sont journalisés
> sous la forme `<site>.access.log` (ex. `jpportal.access.log`). Le motif de
> capture est donc `*.access*.log`. **Adapte ce motif si tes logs suivent une
> autre convention** (ex. `access.log` → motif `access*.log`).

---

## Vue d'ensemble

La solution se compose de deux briques indépendantes :

1. **fail2ban** surveille les logs Apache et bannit toute IP qui génère trop de
   codes 4xx (400/403/404) en peu de temps. Les récidivistes voient leur durée
   de ban doubler à chaque retour.
2. **Un capteur PRTG « SSH Script Advanced »** interroge chaque serveur en SSH,
   exécute un petit script qui retourne le nombre d'IP actuellement bannies, et
   PRTG applique lui-même les seuils et déclenche les notifications. Avantage :
   aucune dépendance au mail local sur les serveurs surveillés, et une chaîne de
   notification unique à maintenir.

---

## Étape 1 — Installer fail2ban

```bash
apt update && apt install fail2ban -y
```

---

## Étape 2 — Créer le filtre (basé sur les 4xx)

**Fichier à créer : `/etc/fail2ban/filter.d/apache-scan.conf`**

```ini
[Definition]
failregex = ^<HOST> -.*"[A-Z]+ [^"]*" (?:400|403|404)\s
ignoreregex =
```

- `<HOST>` est le jeton fail2ban qui capture l'adresse IP.
- L'expression matche n'importe quelle méthode HTTP suivie d'un code
  400, 403 ou 404.

---

## Étape 3 — Tester le filtre AVANT de l'activer

Étape essentielle : `fail2ban-regex` rejoue un log réel et indique combien de
lignes seraient attrapées, sans rien activer. Il prend **un fichier précis**
(pas un glob) — indique le chemin réel d'un de tes logs :

```bash
# Liste d'abord tes logs pour connaître le nom exact
ls -1 /var/log/apache2/*.access.log

# Puis teste le filtre sur l'un d'eux
fail2ban-regex /var/log/apache2/<ton-site>.access.log \
  /etc/fail2ban/filter.d/apache-scan.conf
```

À lire dans la sortie :

- **`matched`** = lignes 4xx détectées (le trafic suspect). Doit être > 0.
- **`missed`** = lignes qui ne correspondent pas (tes requêtes légitimes 200/302…).
  Un chiffre élevé ici est **normal et souhaité** : ce sont les requêtes saines
  que le filtre ignore.
- **`Date template hits`** : vérifie que **toutes** les lignes ont leur date
  reconnue. Si des lignes sont « missed » à cause d'un problème de date, il
  faudra ajouter un `datepattern` — mais le format Apache standard est reconnu
  d'office.

---

## Étape 4 — Créer la jail

**Fichier à créer : `/etc/fail2ban/jail.d/apache-scan.conf`**

```ini
[apache-scan]
enabled   = true
port      = http,https
filter    = apache-scan
logpath   = /var/log/apache2/*.access*.log
maxretry  = 15
findtime  = 60
bantime   = 3600
ignoreip  = 127.0.0.1/8 ::1 <RESEAU_INTERNE>
```

Logique : **15 codes 4xx en 60 secondes → bannissement d'1 heure**, sur
l'ensemble des vhosts couverts par le glob `logpath`. Un utilisateur normal ne
génère jamais 15 erreurs en une minute ; un scanner, si.

- `logpath = /var/log/apache2/*.access*.log` couvre tous les vhosts `*.access.log`
  d'un coup, **y compris les logs actifs tournés non compressés** (`.log.1`).
  fail2ban n'a pas besoin des archives `.gz` (il surveille le temps réel), donc
  **pas de `*` final ici**.
- `ignoreip` : **adapte impérativement** `<RESEAU_INTERNE>` à tes plages de
  confiance pour ne jamais bannir tes propres utilisateurs ou services.
  ⚠️ Vérifie le réseau au chiffre près (une erreur de whitelist rend la
  protection inopérante sur toute une plage, ou bannit à tort).

Vérifie que le motif attrape bien tes fichiers avant d'activer :

```bash
ls -1 /var/log/apache2/*.access*.log
```

---

## Étape 5 — Bannissements progressifs (recommandé)

Pour que les récidivistes soient sanctionnés de plus en plus longtemps, complète
**le même fichier `/etc/fail2ban/jail.d/apache-scan.conf`** avec :

```ini
# --- Bannissements progressifs ---
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
```

Progression obtenue à partir du `bantime` de base (1 h) : **1 h → 2 h → 4 h →
8 h …**, plafonnée à une semaine.

**Prérequis indispensable — la base persistante.** L'incrément s'appuie sur une
base de données qui mémorise l'historique des IP. Elle se configure dans un
**autre fichier** :

**Fichier à vérifier/modifier : `/etc/fail2ban/fail2ban.conf`**

```bash
grep -E "^dbfile|^dbpurgeage" /etc/fail2ban/fail2ban.conf
```

- `dbfile` doit pointer vers `/var/lib/fail2ban/fail2ban.sqlite3` (et **pas**
  `None`), sinon fail2ban oublie tout au redémarrage et l'incrément est inutile.
- `dbpurgeage` (durée de mémorisation d'une IP après son ban) doit être **≥
  `bantime.maxtime`**. Par défaut souvent `1d` (trop court). Pour un maxtime
  d'une semaine, édite `/etc/fail2ban/fail2ban.conf` et passe-le à :

  ```ini
  dbpurgeage = 10d
  ```

---

## Étape 6 — Activer et vérifier

```bash
systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client status apache-scan
```

Contrôles :

```bash
# La whitelist réellement chargée en mémoire
fail2ban-client get apache-scan ignoreip

# La File list du status doit lister tous tes vhosts *.access.log

# Absence d'erreur de démarrage (fichier de log de fail2ban lui-même)
tail -20 /var/log/fail2ban.log
```

> fail2ban agit sur le trafic **à venir**, il ne rejoue pas le passé. Les
> compteurs à 0 juste après l'activation sont donc normaux.

> Rappel : après toute modification d'un fichier de jail, un
> `systemctl reload fail2ban` suffit. Après modification de
> `/etc/fail2ban/fail2ban.conf` (config globale du démon), préfère
> `systemctl restart fail2ban`.

---

## Étape 7 — Supervision via PRTG (capteur SSH Script Advanced)

Le principe : PRTG se connecte en SSH au serveur avec un compte de service,
exécute un script qui renvoie le nombre d'IP bannies **au format XML**, et PRTG
gère seuils et notifications.

### 7.1 — Emplacement du script (piège important)

Le dossier attendu sur la machine Linux cible **dépend du type de capteur** :

| Type de capteur PRTG     | Dossier sur la cible Linux    | Format de sortie attendu        |
|--------------------------|-------------------------------|---------------------------------|
| **SSH Script Advanced**  | `/var/prtg/scriptsxml`        | XML (`<prtg><result>…`)         |
| SSH Script (simple)      | `/var/prtg/scripts`           | `code:valeur:message`           |

Ce guide utilise **SSH Script Advanced** → le script va dans
**`/var/prtg/scriptsxml/`**. (Un capteur Advanced ne trouvera **pas** un script
placé dans `/var/prtg/scripts`.)

```bash
mkdir -p /var/prtg/scriptsxml
```

### 7.2 — Le script

**Fichier à créer : `/var/prtg/scriptsxml/prtg-fail2ban.sh`**

```bash
#!/bin/bash
JAIL="apache-scan"

BANNED=$(sudo /usr/bin/fail2ban-client status "$JAIL" 2>/dev/null \
         | sed -n 's/.*Currently banned:[[:space:]]*//p' | tr -dc '0-9')

if [ -z "$BANNED" ]; then
  echo "<prtg><error>1</error><text>Jail $JAIL indisponible</text></prtg>"
  exit 0
fi

echo "<prtg><result><channel>IP bannies</channel><value>${BANNED}</value><unit>Count</unit><limitmaxwarning>4</limitmaxwarning><limitmaxerror>8</limitmaxerror><limitmode>1</limitmode></result></prtg>"
```

Puis le rendre exécutable :

```bash
chmod +x /var/prtg/scriptsxml/prtg-fail2ban.sh
```

Notes :

- `limitmaxwarning>4` / `limitmaxerror>8` avec `limitmode>1` intègrent les seuils
  directement dans la réponse (warning dès 5 IP, erreur dès 9). Tu peux aussi les
  retirer et piloter les seuils depuis l'interface PRTG — plus pratique à ajuster
  sans rééditer le script sur chaque serveur.
- `tr -dc '0-9'` garantit que `<value>` ne contient qu'un nombre, jamais un
  caractère parasite (évite les erreurs de parsing PRTG).
- **Le chemin `/usr/bin/fail2ban-client` doit correspondre au caractère près**
  à celui autorisé dans le sudoers (étape suivante). Confirme-le avec
  `which fail2ban-client` et corrige si besoin.

### 7.3 — Autoriser le compte PRTG à interroger fail2ban (sudoers)

`fail2ban-client` a besoin de root (il lit le socket
`/var/run/fail2ban/fail2ban.sock`). Le compte SSH de PRTG étant non privilégié,
on lui accorde **uniquement** cette commande en root, sans mot de passe.

D'abord, confirmer le chemin exact du binaire :

```bash
which fail2ban-client
```

**Fichier à créer : `/etc/sudoers.d/prtg-fail2ban`**
(remplace `<COMPTE_PRTG>` par le compte SSH réel utilisé par PRTG, ex. `jpuser`,
et le chemin par celui renvoyé par `which`)

```bash
echo '<COMPTE_PRTG> ALL=(root) NOPASSWD: /usr/bin/fail2ban-client status apache-scan' \
  > /etc/sudoers.d/prtg-fail2ban
chmod 440 /etc/sudoers.d/prtg-fail2ban
visudo -c
```

- `chmod 440` est obligatoire : un fichier sudoers aux mauvaises permissions est
  ignoré silencieusement.
- `visudo -c` valide la syntaxe. **Ne ferme pas ta session root** tant qu'il n'a
  pas confirmé « parsed OK ».

> **Piège éventuel — `requiretty`.** Certaines configs sudo exigent un vrai
> terminal, absent en SSH non interactif (le cas de PRTG). Si le test manuel
> passe mais que PRTG échoue encore, vérifie :
> ```bash
> grep -r requiretty /etc/sudoers /etc/sudoers.d/
> ```
> Si `Defaults requiretty` est présent, ajoute dans
> `/etc/sudoers.d/prtg-fail2ban` :
> ```
> Defaults:<COMPTE_PRTG> !requiretty
> ```

### 7.4 — Tester sous le compte PRTG (pas root)

Reconnecte-toi en SSH **avec le compte PRTG** et lance dans l'ordre :

```bash
# 1. La commande privilégiée doit répondre SANS demander de mot de passe
sudo /usr/bin/fail2ban-client status apache-scan

# 2. Le script doit sortir une ligne de XML propre avec un nombre dans <value>
/var/prtg/scriptsxml/prtg-fail2ban.sh
```

Sortie attendue du script : `<prtg><result><channel>IP bannies</channel><value>0</value>…</result></prtg>`
(le nombre réel d'IP bannies, `0` si aucune). Plus de message « indisponible ».

### 7.5 — Créer le capteur dans PRTG

Sur l'appareil correspondant dans PRTG, ajoute un capteur **« SSH Script
Advanced »**, et dans sa config renseigne **uniquement le nom du fichier**
(`prtg-fail2ban.sh`) — **pas** le chemin complet : PRTG sait qu'il doit chercher
dans `/var/prtg/scriptsxml`. Le capteur doit passer au **vert** avec la valeur
remontée dans le canal « IP bannies ».

### 7.6 — (Optionnel) Tester le déclenchement de l'alerte

Pour vérifier que le capteur réagit au franchissement de seuil, bannis
temporairement des IP de test (plage `203.0.113.0/24`, réservée à la
documentation — aucun risque) :

```bash
# Bannir 5 IP de test pour franchir le seuil warning
for ip in 203.0.113.1 203.0.113.2 203.0.113.3 203.0.113.4 203.0.113.5; do
  sudo fail2ban-client set apache-scan banip $ip
done

# ... vérifier que le capteur PRTG vire au jaune/rouge, puis débannir :
for ip in 203.0.113.1 203.0.113.2 203.0.113.3 203.0.113.4 203.0.113.5; do
  sudo fail2ban-client set apache-scan unbanip $ip
done
```

---

## Récapitulatif des fichiers créés / modifiés

| Fichier | Rôle | Action |
|---------|------|--------|
| `/etc/fail2ban/filter.d/apache-scan.conf` | Filtre 4xx | Créer (étape 2) |
| `/etc/fail2ban/jail.d/apache-scan.conf`   | Jail + incrément | Créer (étapes 4-5) |
| `/etc/fail2ban/fail2ban.conf`             | `dbfile` / `dbpurgeage` | Vérifier/modifier (étape 5) |
| `/var/prtg/scriptsxml/prtg-fail2ban.sh`   | Script capteur PRTG | Créer (étape 7.2) |
| `/etc/sudoers.d/prtg-fail2ban`            | Droit root ciblé pour PRTG | Créer (étape 7.3) |

---

## Variables à adapter par serveur

| Variable            | Où (fichier)                                  | Exemple / valeur                          |
|---------------------|-----------------------------------------------|-------------------------------------------|
| `<RESEAU_INTERNE>`  | `/etc/fail2ban/jail.d/apache-scan.conf` (`ignoreip`) | `157.26.0.0/16`                    |
| `logpath`           | `/etc/fail2ban/jail.d/apache-scan.conf`       | `/var/log/apache2/*.access*.log`          |
| `maxretry` / `findtime` / `bantime` | `/etc/fail2ban/jail.d/apache-scan.conf` | `15` / `60` / `3600`          |
| `bantime.maxtime`   | `/etc/fail2ban/jail.d/apache-scan.conf`       | `1w`                                      |
| `dbpurgeage`        | `/etc/fail2ban/fail2ban.conf`                 | `10d` (≥ maxtime)                         |
| `<COMPTE_PRTG>`     | `/etc/sudoers.d/prtg-fail2ban`                | `jpuser`                                  |
| chemin `fail2ban-client` | script + sudoers                         | `/usr/bin/fail2ban-client` (vérifier `which`) |
| seuils PRTG         | `/var/prtg/scriptsxml/prtg-fail2ban.sh` ou interface PRTG | warning 5 / erreur 9          |

> **Note sur le seuil** : avec l'incrément de ban activé, le nombre d'IP
> simultanément bannies **dérive lentement vers le haut** (les récidivistes
> restent plus longtemps). Surveille la baseline sur 1-2 semaines et remonte les
> seuils si nécessaire.

---

## Commandes clés — exploitation quotidienne

### État et surveillance fail2ban

```bash
# État d'une jail (IP bannies, compteurs, File list)
fail2ban-client status apache-scan

# Vue de toutes les jails actives
fail2ban-client status

# Whitelist effectivement chargée en mémoire
fail2ban-client get apache-scan ignoreip
```

### Historique des bannissements

```bash
# Tous les bans (fichier : /var/log/fail2ban.log)
grep "Ban " /var/log/fail2ban.log

# Nombre de bans par IP (repère les récidivistes : compteur ≥ 2)
grep "Ban " /var/log/fail2ban.log | awk '{print $NF}' | sort | uniq -c | sort -rn

# Bans + débans, chronologique (vérifier le cycle ban → libération auto)
grep -E "Ban|Unban" /var/log/fail2ban.log

# En incluant les logs déjà tournés (.gz)
zgrep -hE "Ban|Unban" /var/log/fail2ban.log*
```

### Actions manuelles

```bash
# Débannir une IP (faux positif)
fail2ban-client set apache-scan unbanip 1.2.3.4

# Bannir une IP manuellement
fail2ban-client set apache-scan banip 1.2.3.4

# Recharger après modif d'une jail (sans couper les jails)
systemctl reload fail2ban
# ou, ciblé sur une jail :
fail2ban-client reload apache-scan

# Redémarrer après modif de /etc/fail2ban/fail2ban.conf (config globale)
systemctl restart fail2ban
```

### Supervision PRTG

```bash
# Rejouer le script exactement comme PRTG le fera (sous le compte PRTG)
/var/prtg/scriptsxml/prtg-fail2ban.sh

# Vérifier le droit sudo du compte PRTG (doit répondre sans mot de passe)
sudo /usr/bin/fail2ban-client status apache-scan

# Valider la syntaxe du sudoers après édition
visudo -c
```

### Analyse des erreurs 4xx dans l'historique

> Ici on utilise le motif **`*.access*.log*`** avec le `*` **final** pour inclure
> les archives compressées `.gz` (contrairement à la jail).

```bash
# Vérifier la profondeur d'historique disponible
ls -lh /var/log/apache2/*.access*.log*

# Répartition globale des codes 4xx
zgrep -h '"[A-Z]* [^"]*" 4' /var/log/apache2/*.access*.log* \
  | awk '{print $9}' | grep '^4' | sort | uniq -c | sort -rn

# IP générant le plus de 4xx (repérer les scanners)
zgrep -h '"[A-Z]* [^"]*" 4[0-9][0-9] ' /var/log/apache2/*.access*.log* \
  | awk '{print $1}' | sort | uniq -c | sort -rn | head -20

# URL les plus souvent en 404
zgrep -h '"[A-Z]* [^"]*" 404 ' /var/log/apache2/*.access*.log* \
  | awk '{print $7}' | sort | uniq -c | sort -rn | head -30

# Évolution des 4xx par jour (repérer un pic)
zgrep -h '"[A-Z]* [^"]*" 4[0-9][0-9] ' /var/log/apache2/*.access*.log* \
  | awk '{print $4}' | cut -d: -f1 | tr -d '[' | sort | uniq -c
```

### Analyse d'un pic d'activité sur une date/heure précise

```bash
# Requêtes par heure sur une date donnée
zgrep -h "30/Aug/2026" /var/log/apache2/*.access*.log* \
  | awk '{print $4}' | cut -d: -f2 | sort | uniq -c

# IP les plus actives sur une heure donnée
zgrep -h "30/Aug/2026:18:" /var/log/apache2/*.access*.log* \
  | awk '{print $1}' | sort | uniq -c | sort -rn | head -20

# URL les plus sollicitées sur cette heure
zgrep -h "30/Aug/2026:18:" /var/log/apache2/*.access*.log* \
  | awk '{print $7}' | sort | uniq -c | sort -rn | head -30

# Répartition minute par minute (repérer un burst concentré)
zgrep -h "30/Aug/2026:18:" /var/log/apache2/*.access*.log* \
  | awk '{print $4}' | cut -d: -f2,3 | sort | uniq -c

# Codes de statut HTTP sur l'heure
zgrep -h "30/Aug/2026:18:" /var/log/apache2/*.access*.log* \
  | awk '{print $9}' | sort | uniq -c | sort -rn

# Identifier le propriétaire d'une IP
whois 1.2.3.4 | grep -iE "country|netname|orgname"
```
