# Films Hors Ligne — app iOS/iPadOS personnelle

Petite app pour **télécharger ou importer des fichiers vidéo** (MP4, M4V, MOV) sur
iPhone/iPad puis les **regarder sans connexion** (mode avion).

- Téléchargement depuis un lien **HTTPS direct** vers un fichier vidéo (votre NAS,
  Dropbox, un serveur perso…).
- Import depuis l'app **Fichiers** (iCloud Drive, clé USB/SSD, « Sur mon iPhone »).
- Lecteur natif Apple (plein écran, Image dans l'image), **reprise là où on s'était
  arrêté**, son actif même avec le bouton silencieux enclenché.
- Aucune dépendance externe, aucune télémétrie, rien n'est envoyé nulle part.

> ⚠️ L'app ne lit que des fichiers dont vous disposez librement. Les films
> Netflix / Prime Video / Disney+ / myCANAL / Apple TV sont protégés (DRM) :
> utilisez **le bouton « Télécharger » de ces apps**, il fonctionne hors ligne.

---

## 0. Pas le temps ? Plan B immédiat (5 minutes)

Si le vol est imminent ou si vous n'avez **ni Mac ni iPad** : installez **VLC**
(gratuit, App Store). Il lit tous les formats (y compris MKV/AVI), importe depuis
Fichiers et propose « Partage via Wi-Fi » pour envoyer les films depuis un
ordinateur. C'est la solution la plus rapide et la plus fiable.

---

## 1. Installer l'app

Le projet est un **App Playground** (`OfflineMovies.swiftpm`) : il s'ouvre
aussi bien dans **Xcode** (Mac) que dans **Swift Playgrounds** (iPad).

### Option A — iPad seul, sans Mac (Swift Playgrounds)
1. Sur l'iPad, installer **Swift Playgrounds** (gratuit, App Store).
2. Copier le dossier `OfflineMovies.swiftpm` sur l'iPad (zipper le dossier,
   l'envoyer par AirDrop ou iCloud Drive, puis le décompresser dans Fichiers).
3. Toucher `OfflineMovies.swiftpm` → il s'ouvre dans Swift Playgrounds → **▶︎ Exécuter**.
4. L'app tourne dans Swift Playgrounds (pas d'icône sur l'écran d'accueil) ;
   les films téléchargés restent disponibles d'une ouverture à l'autre.

### Option B — iPhone ou iPad avec un Mac (Xcode)
1. Installer **Xcode** (gratuit, Mac App Store) et se connecter avec son
   identifiant Apple : *Xcode → Réglages → Comptes → +*.
2. Ouvrir `OfflineMovies.swiftpm` dans Xcode.
3. Cible de l'app → onglet **Signing & Capabilities** → *Team* : choisir
   « (Personal Team) ». Si Xcode signale un identifiant déjà pris, changer le
   *Bundle Identifier* (ex. `local.offlinemovies.monprenom`).
4. Brancher l'iPhone/iPad en USB, accepter « Faire confiance à cet ordinateur ».
5. Sur l'appareil : **Réglages → Confidentialité et sécurité → Mode développeur**
   → activer (redémarrage demandé).
6. Dans Xcode, choisir l'appareil en haut de la fenêtre puis **▶︎ Run** (⌘R).
7. Au premier lancement, l'appareil peut bloquer l'app : **Réglages → Général →
   VPN et gestion de l'appareil** → choisir votre identifiant → *Faire confiance*.

> ⏳ **Important — compte Apple gratuit = app valable 7 jours.** Au-delà, elle ne
> s'ouvre plus (les fichiers restent là). Si le retour est dans plus de 7 jours,
> réinstallez depuis Xcode juste avant le départ, ou utilisez VLC pour le retour.
> Un compte Apple Developer payant porte cette durée à 1 an.

---

## 2. Ajouter des films

**Depuis un lien** : *+ → Télécharger depuis un lien*, coller un lien `https://`
**direct** vers le fichier vidéo.
- Dropbox : remplacer `?dl=0` par `?dl=1` à la fin du lien de partage.
- NAS (Synology, QNAP…) : utiliser un lien de partage « téléchargement direct ».
- Google Drive : les gros fichiers affichent une page d'avertissement au lieu du
  fichier → passer plutôt par l'import depuis Fichiers (app Google Drive installée).
- Les téléchargements se font **app ouverte, écran allumé** (l'app empêche la mise
  en veille pendant le téléchargement). Rester en Wi-Fi.

**Depuis Fichiers** : *+ → Importer depuis Fichiers*. Si le fichier est sur iCloud
Drive, le télécharger d'abord dans Fichiers (appui long → *Télécharger*). Une clé
USB-C / un SSD branché sur l'iPad/iPhone apparaît aussi dans Fichiers.

**Formats** : MP4, M4V, MOV (H.264 ou HEVC). Pour un MKV/AVI : le convertir avec
**HandBrake** (gratuit, Mac/PC), préréglage *« Apple 1080p30 Surround »*, ou utiliser VLC.

**Place** : compter ~1 à 2 Go par film en HD. L'espace libre est affiché en bas
de la liste. Les films ne sont **pas** sauvegardés dans iCloud (exclus de la
sauvegarde pour ne pas la saturer).

---

## 3. Check-list avant le vol ✈️

- [ ] Films téléchargés **à la maison**, en Wi-Fi, la veille.
- [ ] **Test en mode avion** : activer le mode avion et lancer chaque film 10 secondes.
- [ ] Films des apps de streaming téléchargés dans **leurs** apps (vérifier
      la date d'expiration des téléchargements).
- [ ] Appareil chargé + batterie externe ; luminosité réduite = plus d'autonomie.
- [ ] Écouteurs : en mode avion on peut **réactiver le Bluetooth** (AirPods OK).
      Prévoir un adaptateur USB-C/Lightning → jack pour l'écran de l'avion si besoin.
- [ ] Compte gratuit (option B) : l'app a été installée il y a **moins de 7 jours**
      et le restera pour toute la durée d'usage prévue.

---

## Pour les développeurs

- Spécification et contrat d'interfaces : [`SPEC.md`](SPEC.md).
- Swift 5.9, iOS 16+, SwiftUI + AVKit, aucune dépendance tierce.
- Sécurité : HTTPS uniquement, noms de fichiers stockés = UUID (aucun chemin dérivé
  d'une saisie), contrôle d'appartenance au répertoire avant toute opération
  fichier, rejet des réponses HTML, aucune journalisation d'URL/titre.
- Pas de compilation automatique (aucune toolchain Swift côté serveur) : la vérification se fait dans Xcode / Swift Playgrounds.
