#!/bin/bash
## Underline
u=$(tput smul)
## Bold
b=$(tput bold)
## Normal
n=$(tput sgr0)

# --- Guard root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root." >&2
    exit 1
fi

silent=0
reboot=0

while test $# -gt 0
do
    case "$1" in
        -q) silent=1
            ;;
        -r) reboot=1
            ;;
        *) echo "[ $1 ] Bad argument"
            ;;
    esac
    shift
done

# ---------------------------------------------------------------
# Vérification des paquets requis
# ---------------------------------------------------------------
required_packages=()
command -v needrestart &>/dev/null || required_packages+=("needrestart")
command -v checkrestart &>/dev/null || required_packages+=("debian-goodies")

if [ ${#required_packages[@]} -gt 0 ]; then
    echo "${b}${u}Paquets requis manquants${n}"
    echo "${b}${u}------------------------${n}"
    echo
    for pkg in "${required_packages[@]}"; do
        echo "  * ${b}$pkg${n}"
    done
    echo

    read -p "Voulez-vous installer ces paquets maintenant [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_install
    echo

    case $response_install in
        "O" | 'o' | "Oui" | "oui" )
            apt-get -y -qq install "${required_packages[@]}"
            echo "Installation terminée."
            ;;
        *)
            echo "Les paquets ne seront pas installés. Certaines fonctionnalités seront indisponibles."
            ;;
    esac
    echo
fi

# ---------------------------------------------------------------
# Mise à jour des paquets
# ---------------------------------------------------------------
apt-get -qq autoremove
apt-get -qq update

# --- Comptage propre (ignore la ligne "En train de lister..." / "Listing...") ---
count=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)

if [ "$count" -gt 0 ]; then
    if [ "$count" -gt 1 ]; then
        echo "Il y a $count packages à mettre à jour."
    else
        echo "Il y a $count package à mettre à jour."
    fi
    text="les mises à jour"
    [ "$count" -eq 1 ] && text="la mise à jour"
else
    echo "Aucun package à mettre à jour."
fi

echo

if [ "$silent" -eq 0 ]; then
    read -p "Voulez-vous voir la liste [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_list

    echo

    case $response_list in
        "O" | 'o' | "Oui" | "oui" )
            apt list --upgradable 2>/dev/null
            ;;
        *)
            ;;
    esac

    echo

    if [ "$count" -gt 0 ]; then
        read -p "Voulez-vous effectuer $text [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_upgrade

        echo

        case $response_upgrade in
            "O" | 'o' | "Oui" | "oui" )
                apt-get -y upgrade
                ;;
            *)
                ;;
        esac
    fi

elif [ "$silent" -eq 1 ]; then
    # --- Mode silencieux : -y obligatoire pour éviter le blocage ---
    if [ "$count" -gt 0 ]; then
        apt-get -y -qq upgrade
    fi
fi

# ---------------------------------------------------------------
# Redémarrage des services (sans reboot) via needrestart
# ---------------------------------------------------------------
echo
echo "${b}${u}Redémarrage des services concernés${n}"
echo "${b}${u}-----------------------------------${n}"
echo

kernel_reboot=0
services=""

if command -v needrestart &>/dev/null; then
    # Récupération des infos en mode batch (-b = sortie parseable, sans action)
    nr_output=$(needrestart -b 2>/dev/null)

    # NEEDRESTART-KSTA: 3 = noyau mis à jour, reboot nécessaire (1 = OK)
    ksta=$(echo "$nr_output" | grep "^NEEDRESTART-KSTA:" | awk '{print $2}')
    [ "$ksta" = "3" ] && kernel_reboot=1

    # Récupération des services uniquement (NEEDRESTART-SVC), on ignore NEEDRESTART-SESS
    services=$(echo "$nr_output" | grep "^NEEDRESTART-SVC:" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')

    if [ "$silent" -eq 0 ]; then
        echo "Services nécessitant un redémarrage :"
        echo

        if [ -n "$services" ]; then
            for svc in $services; do
                echo "  * $svc"
            done
        else
            echo "  (aucun)"
        fi
        echo

        if [ -n "$services" ]; then
            read -p "Voulez-vous redémarrer ces services [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_nr
            case $response_nr in
                "O" | 'o' | "Oui" | "oui" )
                    needrestart -r a
                    ;;
                *)
                    echo "Aucun service redémarré."
                    ;;
            esac
        fi
    else
        # Mode silencieux : redémarrage automatique si services concernés
        [ -n "$services" ] && needrestart -r a
    fi
else
    # Fallback : checkrestart si disponible (needrestart refusé à l'installation)
    if command -v checkrestart &>/dev/null; then
        checkrestart
    else
        echo "  (aucun outil disponible pour vérifier les services)"
    fi
fi

echo
echo "${b}${u}-----------------------------------${n}"
echo

# ---------------------------------------------------------------
# Reboot machine
# ---------------------------------------------------------------
echo "${b}${u}Faut-il redémarrer la machine ?${n}"
echo "${b}${u}--------------------------------${n}"
echo

need_reboot=0
[ "$kernel_reboot" -eq 1 ] && need_reboot=1
[ -n "$services" ] && need_reboot=1

if [ "$kernel_reboot" -eq 1 ]; then
    echo "  ${b}=> Un nouveau noyau a été installé : un redémarrage est recommandé.${n}"
fi
if [ -n "$services" ]; then
    echo "  ${b}=> Des services ont été redémarrés suite aux mises à jour.${n}"
fi
if [ "$need_reboot" -eq 0 ]; then
    echo "  Aucun redémarrage de la machine nécessaire."
fi
echo

if [ "$reboot" -eq 1 ] && [ "$need_reboot" -eq 1 ]; then
    echo "Le système va redémarrer dans 1 minute, tapez la commande ${b}shutdown -c${n} pour annuler ..."
    shutdown -r +1 --no-wall
elif [ "$reboot" -eq 0 ] && [ "$need_reboot" -eq 1 ]; then
    read -p "Voulez-vous redémarrer la machine [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_reboot
    echo

    case $response_reboot in
        "O" | 'o' | "Oui" | "oui" )
            echo "Le système va redémarrer dans 1 minute, tapez la commande ${b}shutdown -c${n} pour annuler ..."
            shutdown -r +1 --no-wall
            ;;
        *)
            ;;
    esac
fi