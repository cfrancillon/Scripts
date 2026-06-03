#!/bin/bash
## Underline
u=$(tput smul)
## Bold
b=$(tput bold)
## Normal
n=$(tput sgr0)

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

apt-get -qq autoremove
apt-get -qq update

count=$(apt list --upgradable|wc -l)

if [ $count -gt 1 ]; then
	echo Il y a $count packages à mettre à jour.
	text="les mises à jour"
else
	echo Il y a $count package à mettre à jour.
	text="la mise à jour"
fi

echo

if [ $silent -eq 0 ]; then
	read -p "Voulez-vous voir la liste [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_list

	echo

	case $response_list in
		"O" | 'o' | "Oui" | "oui" )
			apt list --upgradable
			;;
		*)
			;;
	esac

	echo

	read -p "Voulez-vous effectuer $text [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_upgrade

	echo

	case $response_upgrade in
	        "O" | 'o' | "Oui" | "oui" )
                	apt-get -y upgrade
        	        ;;
	        *)
        	        ;;
	esac
elif [ $silent -eq 1 ]; then
	apt-get upgrade
fi

echo "${b}${u}Faut-il redémarrer ?${n}"
echo "${b}${u}--------------------${n}"
echo

checkrestart

echo "${b}${u}                    ${n}"
echo "${b}${u}--------------------${n}"
echo

if [ $reboot -eq 1 ]; then
	echo "Le système va redémarrer dans 1 minute, tapez la commande ${b}shutdown -c${n} pour annuler ..."
	shutdown -r -t 1 --no-wall
elif [ $reboot -eq 0 ]; then
	echo
	read -p "Voulez-vous redémarrer [${u}${b}O${n}ui/${u}${b}N${n}on] ? " response_reboot
	echo

	case $response_reboot in
                "O" | 'o' | "Oui" | "oui" )
                        echo "Le système va redémarrer dans 1 minute, tapez la commande ${b}shutdown -c${n} pour annuler ..."
		        shutdown -r -t 1 --no-wall
                        ;;
                *)
                        ;;
        esac
fi