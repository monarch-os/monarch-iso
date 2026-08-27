# Analyse des différences de fonctionnalités avec Omarchy ISO Quattro

## Périmètre et méthode

Cette analyse compare le dépôt Monarch courant à `HEAD` (`0eaf3de`) avec la
branche distante primaire `omarchy-iso/quattro` au commit
`268bac16d351a21d867e37565738f458b11cb06c` du 23 août 2026. Les constats
reposent sur le code et la documentation des deux dépôts, pas sur une comparaison
de noms ou de styles. Les références `quattro:` désignent le fichier à ce commit.

Les différences délibérées de distribution sont traitées comme des capacités
techniques, mais les simples substitutions `omarchy` → `monarch`, la palette du
TUI et Waybar → Noctalia ne sont pas comptées comme des fonctionnalités ISO.

## Synthèse

Monarch couvre le chemin essentiel : installation Btrfs hors ligne, chiffrement
LUKS optionnel activé par défaut, Limine, BIOS/UEFI, autoinstall `cidata`, accès
SSH par clé et exécution du configurateur puis de l'installeur Monarch. Il dispose
en plus d'une base CachyOS cohérente, d'un cache Python hors ligne et d'un meilleur
outillage local pour générer un `cidata` et conserver des VM de test.

Quattro est cependant nettement en avance sur les fonctions d'installation et
de remise à zéro : installation dans l'espace libre sans détruire les données
existantes, provisioning du propriétaire au premier démarrage, Tailscale,
hibernation, orchestration par phases avec validation finale, snapshot usine et
tests bout-en-bout automatisés. Ce sont les écarts à plus forte valeur si
l'objectif est la parité fonctionnelle.

## Matrice de fonctionnalités

| Domaine | Monarch | Quattro | Écart utile |
|---|---|---|---|
| Base système live | CachyOS, dépôts CachyOS prioritaires, `linux-cachyos` | Arch, `linux-t2` | Monarch bénéficie des paquets optimisés CachyOS ; Quattro apporte explicitement les pilotes live Apple T2. |
| Installation hors ligne | Dépôt pacman élagué + cache `pip download` | Dépôt pacman élagué | Monarch couvre aussi les dépendances Python de son installeur hors ligne. |
| Disque entier | Oui, Btrfs, LUKS optionnel par défaut | Oui, Btrfs, LUKS optionnel par défaut | Parité de principe. |
| Installation aux côtés de données existantes | Non : le disque sélectionné est entièrement écrasé | Oui : mode « Free space install », partitions existantes préservées | Fonction majeure absente de Monarch. |
| Autoinstall `cidata` | Oui, avec générateur CLI partageant le générateur du wizard | Oui, mais README orienté création manuelle | Monarch a le meilleur outil de création reproductible. |
| Provisioning différé | Non, un utilisateur est obligatoire pendant l'installation | Oui, image sans identifiants puis création du propriétaire au premier boot | Fonction majeure absente de Monarch. |
| SSH par clé | Oui | Oui, y compris staging pour provisioning différé | Parité hors cas différé. |
| Tailscale autoinstall | Non | Oui, jointure différée et persistante au premier accès réseau | Fonction absente de Monarch. |
| Hibernation | Pas de phase ISO dédiée | Configuration explicite swap/resume avant reconstruction UKI | Fonction/garantie absente de Monarch ISO. |
| Orchestration de l'installation | Script shell linéaire autour du CLI `archinstall` | Machine à phases, `archinstall` utilisé comme bibliothèque | Quattro offre état, timings, erreurs par phase et séquencement plus fin. |
| Validation avant reboot | Vérifications locales ciblées | Validation boot/UKI/hooks/filesystems puis snapshot usine | Couverture de sûreté nettement supérieure dans Quattro. |
| Factory reset | Non pris en charge par l'ISO | Snapshot Btrfs usine et état offline pour reprovisionner | Fonction majeure absente de Monarch. |
| Dashboard d'installation | Affichage `gum` + suivi du log | Dashboard alimenté par un état JSON atomique et comptage de paquets | Expérience et diagnostic supérieurs dans Quattro. |
| Diagnostic d'un média défectueux | Pas de diagnostic spécialisé | Distingue média endommagé, lecture erronée et cause indéterminée à partir des checksums | Quattro donne une cause et une remédiation directement sur l'écran d'échec. |
| Sorties firmware non UTF-8 | Pas de couche explicite ; chaîne shell/CLI différente | Capture tolérante pour le texte descriptif, stricte pour les identifiants de boot | Quattro évite qu'une entrée NVRAM étrangère fasse échouer l'installation sans laisser passer un UUID corrompu. |
| Checksum de release publié | SHA256 calculé et affiché seulement | Fichier `.sha256` généré et téléversé avec l'ISO | Les téléchargements Monarch n'ont pas de sidecar vérifiable fourni par ce workflow. |
| Canaux de build | Une source/ref d'installeur, pas de canaux | stable/rc/edge/dev + paquets runtime/settings associés | Quattro permet davantage de matrices produit ; l'absence est délibérée chez Monarch. |
| Tests ISO automatisés | Tests shell sans VM + boot manuel | Unitaires, acceptance OCR/QMP et scénarios d'intégration QEMU | Plus grand risque de régression bout-en-bout chez Monarch. |
| Outillage VM local | Disques nommés persistants, réutilisation, rendu logiciel optionnel, mode réseau coupé | Boot, harness acceptance et intégration automatisés | Monarch est meilleur pour l'exploration manuelle ; Quattro pour la validation automatisée. |

## Écarts détaillés

### 1. Capacités présentes dans Quattro et absentes de Monarch

#### Installation non destructive dans l'espace libre

Quattro propose, en UEFI, un mode d'installation à côté de données existantes.
Il détecte notamment BitLocker et l'ESP Windows, crée sa propre ESP et sa racine
dans une zone libre, lit les numéros réellement attribués par GPT et sait annuler
uniquement les partitions qu'il vient de créer. Sources :
`quattro:configs/airootfs/root/configurator:503-944` et
`quattro:configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh:1-130`.

Monarch génère au contraire une configuration `device_modifications` avec
`wipe: true`, puis avertit que tout le disque sera écrasé. Sources :
`configs/airootfs/root/write-install-config:79-140` et
`configs/airootfs/root/configurator:387-432`.

**Impact :** Monarch ne convient pas encore à une installation dual-boot ou à
une migration conservant les partitions présentes.

#### Provisioning différé et image générique

Quattro accepte un marqueur `defer-provisioning` à la place des credentials ; le
compte propriétaire, son clavier et ses secrets sont créés au premier boot. Il
prépare le service de provisioning et, si le disque est chiffré, une fenêtre
d'auto-déverrouillage temporaire permettant de remplacer la clé lors de la prise
en main. Sources : `quattro:configs/airootfs/usr/local/bin/omarchy-cidata-load:14-52`,
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py:68-76` et
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:1165-1266`.

Monarch exige toujours `user_configuration.json` **et**
`user_credentials.json`, puis refuse d'installer si aucun utilisateur n'est
nommé. Sources : `configs/airootfs/usr/local/bin/monarch-cidata-load:10-46` et
`configs/airootfs/root/.automated_script.sh:19-35`.

**Impact :** Quattro peut produire une image usine sans identité finale ;
Monarch produit uniquement une machine déjà attribuée à un utilisateur.

#### Factory reset réellement préparé par l'ISO

Quattro conserve le runtime Node nécessaire au reprovisioning hors ligne et crée
un snapshot Btrfs usine après validation. Le scénario d'intégration exerce un
vrai reset tout en vérifiant que des entrées EFI étrangères survivent. Sources :
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:1202-1218`,
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:1785-1846`
et `quattro:README.md:121-133`.

Aucune phase ou test équivalent n'existe dans Monarch.

#### Tailscale via `cidata`

Quattro accepte `tailscale_authkey`, inclut le paquet dans le miroir hors ligne,
active `tailscaled`, ouvre `tailscale0` dans UFW et arme une unité qui retente la
jointure puis efface la clé. Sources : `quattro:README.md:41-63`,
`quattro:builder/archinstall.packages:1-17` et
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:1570-1643`.

Monarch n'accepte pas ce fichier et son `builder/archinstall.packages` ne contient
pas `tailscale`.

#### Hibernation installée au bon moment

Quattro exécute `omarchy-hibernation-setup --force --no-rebuild` avant la
finalisation Limine, afin que les hooks resume et la ligne de commande entrent
dans la construction UKI finale. Source :
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:932-950`.

La séquence Monarch ne contient aucune étape hibernation entre archinstall et
l'installeur Monarch (`configs/airootfs/root/.automated_script.sh:289-295`). Cette
différence décrit la garantie fournie par l'ISO ; elle ne prouve pas que le
runtime Monarch ne puisse jamais configurer l'hibernation par ailleurs.

#### Orchestrateur, validation et dashboard

Quattro remplace le simple appel au CLI `archinstall` par un orchestrateur qui
l'utilise comme bibliothèque et ordonne quatorze phases, dont boot Limine,
login, DNS, SSH, Tailscale, validation et snapshot. Sources :
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py:1-65` et
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/archinstall_adapter.py:58-169`.
Chaque phase publie atomiquement son état, son résultat et son temps ; le
dashboard peut aussi comparer le nombre de paquets prévu et installé. Source :
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/phases.py:24-104`.

Monarch appelle `archinstall --silent`, puis l'installeur Monarch dans le chroot,
avec un suivi de log et quelques contrôles ciblés. Sources :
`configs/airootfs/root/.automated_script.sh:37-56` et
`configs/airootfs/root/.automated_script.sh:183-286`.

#### Tests automatisés du vrai ISO

Quattro fournit :

- un harness acceptance pilotant le TUI, le reboot, SDDM et le bureau via
  QMP, captures écran, OCR et clavier virtuel ;
- des scénarios d'intégration QEMU basés sur une installation `cidata` réutilisable ;
- une fixture dédiée à la préservation de partitions de type Windows.

Sources : `quattro:README.md:93-133`, `quattro:bin/omarchy-iso-test`,
`quattro:test/integration` et `quattro:bin/omarchy-iso-test-windows-disk`.

Monarch a quatre suites shell rapides et un boot QEMU essentiellement manuel
(`AGENTS.md`, section « Build / Test » ; `test/*.sh`). Son mode `offline` est
précieux pour vérifier l'absence de réseau, mais il n'apporte pas les assertions
bout-en-bout de Quattro.

#### Diagnostic explicite d'un support d'installation corrompu

Lorsqu'un paquet lu depuis le miroir bind-monté est rejeté comme corrompu,
Quattro analyse le journal et compare, si le paquet a survécu, son SHA256 au
checksum du dépôt. Il peut alors distinguer un contenu réellement endommagé
d'une lecture intermittente ; sinon il nomme honnêtement les deux possibilités.
Le dashboard affiche ensuite les remèdes adaptés : vérifier ou télécharger à
nouveau l'ISO, réécrire ou changer la clé/port, voire tester la mémoire. Sources :
`quattro:configs/airootfs/usr/local/bin/omarchy-install-diagnose-media:1-124` et
`quattro:configs/airootfs/usr/local/bin/omarchy-install-dashboard:656-713,844-853`.
Le comportement est couvert par
`quattro:test/unit/install-media-diagnosis-test.sh`.

Monarch journalise l'échec d'archinstall, mais ne possède ni analyseur de média,
ni message spécialisé, ni test équivalent. C'est un écart de diagnostic et de
support, pas du mécanisme d'installation hors ligne lui-même.

#### Tolérance contrôlée aux sorties non UTF-8

Quattro centralise la capture des commandes : les octets invalides d'un libellé
ou chemin descriptif NVRAM sont remplacés pour qu'une entrée firmware étrangère
ne tue pas l'installation, tandis qu'une valeur structurante (UUID, device) est
refusée si elle a été altérée. Sources :
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/command.py:1-54`,
`quattro:configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:797-924`
et `quattro:test/unit/test_command_capture.py`.

Monarch n'a pas cette couche, mais son architecture shell + CLI archinstall est
différente : ce gap ne signifie donc pas automatiquement qu'il reproduit le bug
Python de Quattro. Il lui manque en revanche une politique et des tests explicites
pour les métadonnées firmware/fichiers non UTF-8.

#### Checksum de release distribué

Quattro écrit un sidecar `<iso>.sha256` au format accepté par
`sha256sum -c`, échoue si sa création échoue, puis téléverse ISO, signature et
checksum en agrégeant leurs statuts. Sources :
`quattro:bin/omarchy-iso-release:51-72`,
`quattro:bin/omarchy-iso-upload:13-33` et `quattro:README.md:135-145`.

Monarch calcule et affiche le SHA256 pendant la release, mais ne l'écrit pas dans
un fichier et l'uploader ne publie que l'ISO et l'éventuelle signature
(`bin/monarch-iso-release:64-73`, `bin/monarch-iso-upload:13-17`). Le checksum
n'est donc pas livré par ce workflow à l'utilisateur qui télécharge l'image.

### 2. Capacités propres à Monarch

#### Base CachyOS complète

Monarch construit dans `cachyos/cachyos:latest`, démarre le live avec
`linux-cachyos`, installe les trois keyrings Arch/CachyOS/Monarch et donne la
priorité au dépôt CachyOS. Sources : `bin/monarch-iso-make:73-139`,
`builder/build-iso.sh:7-15`, `builder/build-iso.sh:74-94` et
`configs/pacman-online.conf:1-31`.

Quattro construit dans `archlinux/archlinux:latest` et son live utilise
`linux-t2` (`quattro:bin/omarchy-iso-make:121-161` et
`quattro:builder/build-iso.sh:85-107`). L'effet fonctionnel n'est pas une simple
marque : Monarch sélectionne les paquets optimisés CachyOS ; Quattro offre des
pilotes live T2 que Monarch délègue au système installé.

#### Cache Python hors ligne

Monarch télécharge `pip` et toutes les entrées `install/python.packages` du dépôt
Monarch dans `/var/cache/python/offline`, puis bind-monte ce cache dans la cible.
Sources : `builder/build-iso.sh:156-159` et
`configs/airootfs/root/.automated_script.sh:238-240`.

Quattro ne possède pas de cache Python analogue. C'est une capacité propre liée
aux besoins de l'installeur Monarch, pas nécessairement un avantage de taille ou
de vitesse.

#### Générateur `cidata` qui réutilise le schéma réel

`bin/monarch-iso-cidata` expose disque, taille, identité, fuseau, clavier,
chiffrement, mot de passe et clés SSH, puis source directement
`write-install-config`, le même générateur que le configurateur. Il valide aussi
les JSON et les clés avant de créer l'ISO. Sources :
`bin/monarch-iso-cidata:22-40`, `bin/monarch-iso-cidata:63-132` et
`configs/airootfs/root/configurator:451-476`.

Quattro charge bien un `cidata`, mais ne fournit pas de commande hôte équivalente
dans `bin/`. Sa documentation recommande de récupérer un jeu initial produit par
une installation interactive, puis montre l'assemblage manuel de ces fichiers
avec `genisoimage` (`quattro:README.md:31-70`). Quattro génère aussi ses médias
dans les harness de test, mais sans exposer un outil public autonome comparable.

#### Ergonomie de test manuel

Monarch peut nommer et conserver un couple disque/NVRAM, le rebooter sans ISO,
choisir le port SSH, désactiver le réseau et utiliser un rendu logiciel côté
hôte. Sources : `README.md:32-72`, `bin/monarch-vm` et
`bin/monarch-iso-boot`. Quattro a une automatisation beaucoup plus riche, mais
pas cette même ergonomie de collection de VM persistantes documentée.

#### Runtime de conteneur configurable

Monarch permet de remplacer Docker avec `BUILDER_CMD`, tout en gardant Docker par
défaut (`bin/monarch-iso-make:73-139`). Quattro invoque Docker directement
(`quattro:bin/omarchy-iso-make:161`). C'est un avantage de portabilité de build,
pas une fonctionnalité visible dans l'ISO final.

### 3. Différences délibérées, à ne pas traiter comme des oublis simples

Quattro propose les canaux `stable`, `rc`, `edge` et `dev`, sélectionne des
paquets runtime/settings correspondants et sépare leurs caches. Sources :
`quattro:bin/omarchy-iso-make:27-60`,
`quattro:builder/build-iso.sh:4-22` et `quattro:README.md:9-21`.

Monarch accepte une ref d'installeur et un checkout local, mais conserve un seul
`pacman-online.conf` et aucun modèle de canal (`bin/monarch-iso-make:23-54`).
`AGENTS.md` qualifie explicitement cette absence de divergence architecturale.
La porter demanderait donc une décision produit, et non un simple sync.

De même, il ne faut pas porter `linux-t2`, le keyring Omarchy, ses miroirs ou ses
patches archinstall historiques : ils contrediraient la base CachyOS et les choix
documentés de Monarch.

## Priorités suggérées pour réduire l'écart

1. **Installer dans l'espace libre** : valeur utilisateur la plus directe, mais
   surface de risque disque/boot la plus élevée ; porter ensemble les helpers,
   rollback, validations et tests de partitionnement.
2. **Tests QEMU d'intégration** : à faire avant ou avec le point précédent pour
   éviter qu'une régression destructive reste invisible.
3. **Orchestration et validation par phases** : apporte diagnostic, boot fiable
   et point d'ancrage aux fonctions suivantes ; traduire les hypothèses Arch/T2
   vers CachyOS plutôt que copier les fichiers tels quels.
4. **Provisioning différé + snapshot usine** : à concevoir avec le runtime
   Monarch, car le protocole de premier boot appartient autant à `monarch` qu'à
   l'ISO.
5. **Tailscale et hibernation** : fonctions plus isolées, à prendre seulement si
   elles correspondent au produit Monarch ; Tailscale élargit notamment la
   gestion de secrets de `cidata`.

## Conclusion

Monarch n'est pas simplement « Quattro rebrandé en retard » : sa base CachyOS,
son cache Python et ses outils de génération/test manuel sont des divergences
réelles. En revanche, sur le cœur du produit ISO, Quattro possède aujourd'hui
une chaîne beaucoup plus complète et vérifiable. Les trois gaps les plus
importants sont la préservation des données existantes, le provisioning/factory
reset et l'automatisation des tests du vrai ISO.
