package {
    import flash.display.Graphics;
    import flash.display.Shape;
    import flash.display.Sprite;
    import flash.display.StageAlign;
    import flash.display.StageDisplayState;
    import flash.display.StageScaleMode;
    import flash.events.Event;
    import flash.events.FullScreenEvent;
    import flash.events.KeyboardEvent;
    import flash.events.MouseEvent;
    import flash.events.NetStatusEvent;
    import flash.events.SecurityErrorEvent;
    import flash.events.TimerEvent;
    import flash.geom.Point;
    import flash.media.SoundTransform;
    import flash.media.Video;
    import flash.net.NetConnection;
    import flash.net.NetStream;
    import flash.system.Security;
    import flash.text.TextField;
    import flash.text.TextFormat;
    import flash.ui.Keyboard;
    import flash.ui.Mouse;
    import flash.utils.Timer;
    import flash.utils.getTimer;

    // Lecteur Flash minimal pour JellyDinosaur (client Jellyfin ultra-leger pour vieux navigateurs) :
    // lit un flux progressif distant (FLV via HTTP) dans le plug-in Flash Player ou un Projecteur Flash
    // Standalone. Barre de controle dessinee entierement en vectoriel (pas de police/glyphe Unicode),
    // avec barre de progression (indicateur seul), muet + slider de volume, et plein ecran (bouton ou
    // double-clic). Respecte le ratio d'aspect natif de la video. Reconnecte automatiquement en cas
    // d'erreur reseau.
    //
    // === PAS de seek dans ce lecteur : une seule connexion HTTP par instance, par conception ===
    //
    // Ce lecteur n'offre AUCUN deplacement dans la video (pas de boutons -/+, pas de fleches
    // clavier, barre de progression non cliquable). Le positionnement se fait AVANT lecture, via le
    // "Demarrer a" de l'app (index.html), qui pose startTimeTicks dans l'URL du flux et transmet la
    // meme valeur en flashvar `startseconds` pour l'affichage du temps absolu. Changer de position
    // = relancer une lecture depuis l'app (nouvel onglet/nouveau lien projector), ce qui detruit
    // l'instance du lecteur et laisse l'OS fermer la connexion.
    //
    // Pourquoi : il est IMPOSSIBLE d'interrompre un transfert HTTP depuis l'ActionScript du Flash
    // Player projector standalone (variante 35.x, universelle). Verifie empiriquement, au proxy
    // local instrumente + nettop, sur CHAQUE API candidate : NetStream.close(), remplacement de
    // source par play() sur le meme NetStream, URLStream.close(), NetStream.dispose(), et
    // Loader.unloadAndStop(true) d'un SWF enfant en cours de lecture -- dans TOUS les cas le
    // lecteur continue de lire la socket (en jetant les donnees) jusqu'a la fin de la reponse. Sur
    // un transcodage en direct, la reponse ne se termine qu'a la fin du film : tout mecanisme de
    // seek par reconnexion (startTimeTicks + nouveau playSessionId, l'approche precedente de ce
    // lecteur) laissait donc un telechargement eternel de plus a chaque seek -- debit cumulatif
    // observe jusqu'a 10 Mo/s, lien sature, re-tamponnage du flux actif en boucle. Cote serveur,
    // Jellyfin ne coupe jamais un flux progressif de lui-meme (ni au demarrage d'un nouveau
    // transcodage pour le meme deviceId, ni via DELETE /Videos/ActiveEncodings tant que la
    // connexion est ouverte), et la seule commande d'arret qui fonctionne (POST
    // /Sessions/Playing/Stopped) exige un crossdomain.xml des que le SWF n'est pas servi par le
    // domaine de Jellyfin -- dependance de deploiement refusee. D'ou ce choix radical : une
    // instance de lecteur = UNE connexion de flux, ouverte a la construction, jamais remplacee.
    //
    // Seule exception : la reprise apres erreur reseau (handlePlaybackFailure), qui rejoue l'URL
    // avec startTimeTicks = position courante et un playSessionId frais (voir buildResumeUrl()) --
    // sans risque de fuite, puisque la connexion precedente est deja morte (c'est l'erreur qui a
    // declenche la reprise). Le playSessionId doit etre renouvele car le serveur identifie le
    // fichier de sortie d'un transcodage par hash(chemin media + user-agent + deviceId +
    // playSessionId), startTimeTicks n'entrant pas dans ce hash : reutiliser l'ancien id ferait
    // reservir l'ancien fichier depuis l'octet 0.
    //
    // La pause ne coupe pas le telechargement (comportement progressif de Flash, et on ne peut ni
    // le borner ni fermer/rouvrir la connexion, cf. ci-dessus) : le flux continue de se charger
    // pendant la pause, borne par la taille du film -- c'est le prix de la fiabilite, et c'est
    // aussi du tampon utilisable a la reprise.
    //
    // Suivi du temps :
    // - NetStream.time demarre a 0 quel que soit startTimeTicks. Le decalage absolu du debut de la
    //   connexion courante est _streamStartOffset (initialise avec la flashvar `startseconds`,
    //   remplace a chaque reprise apres erreur reseau) ; la position reelle est
    //   _streamStartOffset + NetStream.time (voir currentPlaybackTime()).
    // - La tete de telechargement (barre "charge") est _streamStartOffset +
    //   max(NetStream.time + NetStream.bufferLength), completee par l'estimation
    //   bytesLoaded / estimatedbitrate.
    //
    // Flashvars acceptees :
    //   file             (obligatoire) : URL du flux a lire (progressif HTTP, FLV), portant deja
    //                    startTimeTicks si un point de depart a ete choisi dans l'app
    //   autoplay         (optionnel, defaut "true")
    //   startseconds     (optionnel, secondes) : position absolue correspondant au debut du flux
    //                    (le startTimeTicks de l'URL, converti), pour afficher le temps reel
    //   knownduration    (optionnel, secondes) : duree totale reelle, connue cote app (RunTimeTicks
    //                    Jellyfin) car absente des metadonnees du flux (transcodage en direct =
    //                    duration=0 dans le FLV)
    //   estimatedbitrate (optionnel, bits/seconde) : debit video+audio demande au transcodage, utilise
    //                    comme plancher pour estimer la tete de telechargement
    //
    // frameRate=60 : sans balise [SWF(...)], mxmlc genere un SWF a 24 im/s. Le compositing d'un
    // Video/NetStream a l'ecran est cadence sur le frameRate de la Stage (independamment du debit de
    // decodage reel du flux) -- a 24 im/s la Stage ne peut afficher que 24 images par seconde, quelle
    // que soit la fluidite du decodage, ce qui saccade toute source dont le framerate reel depasse 24
    // (l'appli demande jusqu'a maxFramerate=30 au transcodage, cf. index.html). Flash Player 9 en
    // plugin navigateur n'expose aucune API fiable pour lire le Hz reel de l'ecran (pas d'equivalent
    // a flash.display.Screen, reserve a AIR), donc valeur fixe : 60 laisse une marge confortable
    // au-dela du plafond actuel de 30 et couvre le Hz d'ecran le plus courant pour la fluidite de
    // l'interface (barre de progression, infobulle) -- la video elle-meme ne peut de toute facon pas
    // afficher plus d'images distinctes par seconde que n'en fournit le flux.
    [SWF(frameRate="60")]
    public class JellyDinosaurFlashPlayer extends Sprite {

        private static const BAR_HEIGHT:Number = 34;
        private static const BAR_PADDING:Number = 8;
        private static const BUTTON_SIZE:Number = 18;
        private static const TIME_SLOT_WIDTH:Number = 92;
        private static const VOLUME_WIDTH:Number = 50;
        private static const PROGRESS_HEIGHT:Number = 6;
        private static const COLOR_BG:uint = 0x000000;
        private static const COLOR_BAR_BG:uint = 0x1a1a1a;
        private static const COLOR_TRACK:uint = 0x4d4d4d;
        private static const COLOR_LOADED:uint = 0x808080;
        private static const COLOR_PLAYED:uint = 0x3cacc8;
        private static const COLOR_ICON:uint = 0xffffff;
        private static const HIDE_DELAY_MS:Number = 3000;
        // Delai avant d'agir sur un simple clic (pause/reprise), pour laisser le temps a un eventuel
        // second clic de former un double-clic (plein ecran).
        private static const CLICK_DELAY_MS:Number = 250;
        private static const VOLUME_STEP:Number = 0.05;
        private static const BUFFER_TIME_SECONDS:Number = 3;
        private static const MAX_RETRIES:int = 5;
        private static const RETRY_DELAY_MS:Number = 2000;
        // Detection d'avancement de la lecture : sert a la fois a masquer l'indicateur de
        // re-tamponnage, et a detecter la reprise effective de la lecture apres une reconnexion
        // d'erreur reseau (voir onUpdateTick()) -- mais uniquement utile si la lecture est en
        // cours : a l'arret (pause), le temps n'avance jamais, voir NetStream.Buffer.Full ci-dessous.
        private static const ADVANCE_EPSILON_S:Number = 0.05;
        private static const ADVANCE_GOOD_POLLS:int = 2;
        // Garde-fou : si ni l'avancement du temps ni NetStream.Buffer.Full ne concluent la
        // reconnexion (edge case), on arrete quand meme d'afficher "Buffering..." indefiniment
        // apres ce delai.
        private static const RECONNECT_TIMEOUT_MS:Number = 6000;

        private var _video:Video;
        private var _connection:NetConnection;
        private var _stream:NetStream;
        private var _soundTransform:SoundTransform;

        private var _lastUrl:String = "";
        private var _knownDuration:Number = 0;
        private var _estimatedBitrate:Number = 0;
        private var _videoNativeWidth:Number = 0;
        private var _videoNativeHeight:Number = 0;
        private var _isPlaying:Boolean = false;
        private var _isFullscreen:Boolean = false;
        private var _ended:Boolean = false;

        // --- Etat de la reconnexion apres erreur reseau (seul cas de remplacement du flux) ---
        // Cible logique affichee pendant qu'une reconnexion est en cours ; -1 = pas de reconnexion
        // en cours.
        private var _reconnectIntent:Number = -1;
        // Nombre de sondages consecutifs ou la lecture a avance depuis la reconnexion (voir
        // ADVANCE_GOOD_POLLS).
        private var _reconnectGoodPolls:int = 0;
        // Instant (getTimer) de la reconnexion emise, pour le garde-fou RECONNECT_TIMEOUT_MS.
        private var _reconnectIssuedAt:Number = 0;
        // Decalage absolu (secondes) du point de depart de la connexion NetStream courante :
        // NetStream.time demarre a 0 quel que soit le startTimeTicks de l'URL (voir strategie en
        // tete de fichier). Initialise avec la flashvar `startseconds`.
        private var _streamStartOffset:Number = 0;

        // Tete de telechargement : maximum observe de time + bufferLength sur la connexion courante.
        private var _maxHeadSeconds:Number = 0;

        // Re-tamponnage hors reconnexion (reseau qui cale en lecture normale).
        private var _rebuffering:Boolean = false;
        private var _rebufferGoodPolls:int = 0;

        private var _lastPolledTime:Number = 0;

        private var _retryCount:int = 0;
        private var _retryTimer:Timer;
        private var _retryResumeAt:Number = 0;

        private var _clickTimer:Timer;

        private var _statusText:TextField;
        // Vrai quand le statut affiche est "Buffering..." (masquable sans risquer d'effacer une
        // erreur).
        private var _statusIsBuffering:Boolean = false;

        private var _hitArea:Sprite;

        private var _controlBar:Sprite;
        private var _controlBarBg:Shape;
        private var _playPauseButton:Sprite;
        private var _fullscreenButton:Sprite;
        private var _timeText:TextField;

        // Barre de progression : PUR INDICATEUR, non interactive (pas de seek dans ce lecteur,
        // voir strategie en tete de fichier).
        private var _progressTrack:Sprite;
        private var _progressBase:Shape;
        private var _progressLoaded:Shape;
        private var _progressPlayed:Shape;
        private var _progressHandle:Shape;
        private var _progressWidth:Number = 0;

        private var _volumeButton:Sprite;
        private var _volumeTrack:Sprite;
        private var _volumeHit:Shape;
        private var _volumeBase:Shape;
        private var _volumeFill:Shape;
        private var _volumeHandle:Shape;
        private var _isDraggingVolume:Boolean = false;
        private var _volume:Number = 1.0;
        private var _isMuted:Boolean = false;
        private var _volumeBeforeMute:Number = 1.0;

        private var _hideTimer:Timer;
        private var _updateTimer:Timer;

        public function JellyDinosaurFlashPlayer() {
            if (stage) {
                init();
            } else {
                addEventListener(Event.ADDED_TO_STAGE, init);
            }
        }

        private function init(event:Event = null):void {
            Security.allowDomain("*");
            Security.allowInsecureDomain("*");

            stage.align = StageAlign.TOP_LEFT;
            stage.scaleMode = StageScaleMode.NO_SCALE;
            stage.addEventListener(Event.RESIZE, onStageResize);
            stage.addEventListener(FullScreenEvent.FULL_SCREEN, onFullScreenChange);

            drawBackground();

            var params:Object = (root && root.loaderInfo) ? root.loaderInfo.parameters : {};
            _lastUrl = (params["file"] != undefined) ? String(params["file"]) : "";
            var autoplay:Boolean = (params["autoplay"] != undefined) ? (String(params["autoplay"]) != "false") : true;

            _knownDuration = parseFloat((params["knownduration"] != undefined) ? params["knownduration"] : "0");
            if (isNaN(_knownDuration) || _knownDuration < 0) {
                _knownDuration = 0;
            }
            _estimatedBitrate = parseFloat((params["estimatedbitrate"] != undefined) ? params["estimatedbitrate"] : "0");
            if (isNaN(_estimatedBitrate) || _estimatedBitrate < 0) {
                _estimatedBitrate = 0;
            }
            // Position absolue du debut du flux : l'URL `file` porte deja startTimeTicks, cette
            // flashvar en est l'equivalent en secondes pour l'affichage du temps reel (voir
            // "Suivi du temps" en tete de fichier).
            _streamStartOffset = parseFloat((params["startseconds"] != undefined) ? params["startseconds"] : "0");
            if (isNaN(_streamStartOffset) || _streamStartOffset < 0) {
                _streamStartOffset = 0;
            }

            _video = new Video();
            _video.smoothing = true;
            addChild(_video);

            // Surface interactive explicite couvrant tout le stage, au-dessus de la video mais sous la
            // barre de controle : flash.media.Video n'herite pas d'InteractiveObject et ne declenche
            // pas fiablement les evenements souris. Cible du clic simple (pause/reprise) et du
            // double-clic (plein ecran), y compris sur les bandes noires du letterboxing.
            _hitArea = new Sprite();
            _hitArea.doubleClickEnabled = true;
            _hitArea.addEventListener(MouseEvent.CLICK, onHitAreaClick);
            _hitArea.addEventListener(MouseEvent.DOUBLE_CLICK, onHitAreaDoubleClick);
            addChild(_hitArea);

            buildControlBar();

            _statusText = createTextField(0xFFFFFF, 16, true);
            _statusText.text = "Loading...";
            addChild(_statusText);

            // Un seul point d'ecoute des mouvements de souris, au niveau du stage : tous les
            // MOUSE_MOVE des enfants y remontent par bulle. Gere l'activite (reafficher la barre).
            stage.addEventListener(MouseEvent.MOUSE_MOVE, onStageMouseMove);
            stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
            stage.focus = stage;

            _hideTimer = new Timer(HIDE_DELAY_MS, 1);
            _hideTimer.addEventListener(TimerEvent.TIMER, onHideTimer);

            _updateTimer = new Timer(200);
            _updateTimer.addEventListener(TimerEvent.TIMER, onUpdateTick);
            _updateTimer.start();

            layoutAll();
            showControlBar();
            updateVolumeUI();

            // Les dimensions d'un TextField autoSize fraichement cree ne sont pas toujours fiables
            // avant le premier rendu : on reapplique la mise en page apres la premiere image.
            addEventListener(Event.ENTER_FRAME, onFirstFrame);

            if (_lastUrl == "") {
                showStatus("No URL provided (missing 'file' parameter).");
                return;
            }

            _soundTransform = new SoundTransform(_volume);
            _isPlaying = autoplay;
            connectAndPlay(_lastUrl);
            drawPlayPauseIcon();
            if (!autoplay) {
                showControlBar();
            }
        }

        private function onFirstFrame(event:Event):void {
            removeEventListener(Event.ENTER_FRAME, onFirstFrame);
            layoutControlBar();
        }

        // Demarre la lecture de l'URL donnee sur le NetStream UNIQUE (cree paresseusement au tout
        // premier appel, puis reutilise a vie). Deux cas d'appel seulement : lecture initiale
        // (url = _lastUrl) et reprise apres erreur reseau (url = _lastUrl + startTimeTicks +
        // playSessionId frais, voir reconnectAt()) -- il n'y a PAS de seek dans ce lecteur (voir
        // strategie en tete de fichier). La Video n'est attachee qu'une seule fois, a la creation
        // (le re-attachement etait une source de regressions : ecran noir avec l'audio qui
        // continuait).
        private function connectAndPlay(url:String):void {
            if (!_connection) {
                _connection = new NetConnection();
                _connection.addEventListener(NetStatusEvent.NET_STATUS, onConnectionStatus);
                _connection.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);
                _connection.connect(null);
            }
            if (!_stream) {
                _stream = new NetStream(_connection);
                _stream.client = this;
                _stream.bufferTime = BUFFER_TIME_SECONDS;
                _stream.addEventListener(NetStatusEvent.NET_STATUS, onStreamStatus);
                _stream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);
                _video.attachNetStream(_stream);
            }

            applyVolume();

            // Nouvelle lecture = nouveau telechargement depuis zero : la tete observee repart de
            // zero elle aussi.
            _maxHeadSeconds = 0;
            _lastPolledTime = 0;

            _stream.play(url);
            applyStreamPlayState();
        }

        // Applique l'etat lecture/pause du flux selon l'etat utilisateur. resume()/pause() sont
        // idempotents.
        private function applyStreamPlayState():void {
            if (!_stream) {
                return;
            }
            if (_isPlaying) {
                _stream.resume();
            } else {
                _stream.pause();
            }
        }

        // --- Callbacks NetStream (appeles automatiquement par le moteur, doivent etre publics) ---

        public function onMetaData(info:Object):void {
            if (!_statusIsBuffering) {
                hideStatus();
            }
            if (info.width && info.height) {
                _videoNativeWidth = Number(info.width);
                _videoNativeHeight = Number(info.height);
                layoutVideo();
            }
        }

        public function onCuePoint(info:Object):void {
        }

        // Garde d'identite (idem onStreamStatus/onSecurityError) : ceinture et bretelles. Avec le
        // NetStream unique il ne devrait plus exister d'objets au rebut, mais seuls les evenements
        // du flux/de la connexion COURANTS doivent piloter la machine a etats, sous peine de
        // retries en cascade si un objet residuel emettait encore (Play.Failed, etc.).
        private function onConnectionStatus(event:NetStatusEvent):void {
            if (event.target != _connection) {
                return;
            }
            if (event.info && event.info.code == "NetConnection.Connect.Failed") {
                handlePlaybackFailure();
            }
        }

        private function onStreamStatus(event:NetStatusEvent):void {
            if (event.target != _stream) {
                return;
            }
            var code:String = (event.info && event.info.code) ? String(event.info.code) : "";
            if (code == "NetStream.Play.StreamNotFound" || code == "NetStream.Play.Failed") {
                handlePlaybackFailure();
            } else if (code == "NetStream.Buffer.Empty") {
                // Pendant une reconnexion, etat attendu (deja couvert par "Buffering..."). En
                // lecture normale : re-tamponnage, meme indicateur, masque par le polling une fois
                // la lecture repartie.
                if (_reconnectIntent < 0 && _isPlaying && !_ended) {
                    _rebuffering = true;
                    _rebufferGoodPolls = 0;
                    showBufferingIndicator();
                }
            } else if (code == "NetStream.Buffer.Full") {
                _retryCount = 0;
                // Signal independant de l'etat lecture/pause (le telechargement progresse meme en
                // pause) : conclut une reconnexion en attente meme si _stream.time n'avance jamais
                // faute de lecture active (sinon "Buffering..." resterait affiche indefiniment tant
                // que l'utilisateur ne relance pas la lecture -- voir aussi le garde-fou
                // RECONNECT_TIMEOUT_MS dans onUpdateTick() pour les cas ou meme ce signal ne
                // suffit pas).
                if (_reconnectIntent >= 0) {
                    endReconnect();
                }
            } else if (code == "NetStream.Play.Start") {
                _retryCount = 0;
            } else if (code == "NetStream.Play.Stop") {
                // Fin reelle du contenu uniquement (Play.Stop peut aussi survenir dans des remous
                // de reconnexion) : hors reconnexion et pres de la fin annoncee.
                // currentPlaybackTime() (position absolue) et non _stream.time brut (local a la
                // connexion courante, qui demarre a 0 quel que soit startTimeTicks).
                if (_reconnectIntent < 0 && _knownDuration > 0 && _stream && currentPlaybackTime() > _knownDuration - 10) {
                    _ended = true;
                    _isPlaying = false;
                    _rebuffering = false;
                    hideBufferingIndicator();
                    drawPlayPauseIcon();
                    showControlBar();
                }
            }
        }

        private function onSecurityError(event:SecurityErrorEvent):void {
            if (event.target != _stream && event.target != _connection) {
                return;
            }
            showStatus("Security error (domain not allowed): " + event.text);
        }

        // Reconnexion apres erreur reseau, avec nombre de tentatives limite. La position de reprise
        // est la position logique courante (donc la cible de la reconnexion si une etait en cours).
        private function handlePlaybackFailure():void {
            if (_retryCount >= MAX_RETRIES) {
                cancelReconnect();
                _rebuffering = false;
                showStatus("Network error: giving up after " + MAX_RETRIES + " attempts.");
                return;
            }
            _retryCount++;
            _retryResumeAt = currentPlaybackTime();
            cancelReconnect();
            _rebuffering = false;
            showStatus("Network error, retrying (" + _retryCount + "/" + MAX_RETRIES + ")...");

            if (_retryTimer) {
                _retryTimer.stop();
            }
            _retryTimer = new Timer(RETRY_DELAY_MS, 1);
            _retryTimer.addEventListener(TimerEvent.TIMER, onRetryTimer);
            _retryTimer.start();
        }

        // Reprise apres erreur reseau : reconnexion DIRECTE a la position de reprise, avec un
        // playSessionId frais (via reconnectAt), et non pas connectAndPlay(_lastUrl). Rejouer
        // l'URL d'origine ferait servir par Jellyfin le fichier de la session initiale DEPUIS
        // L'OCTET 0 a pleine vitesse de ligne : ce fichier continue de grossir cote serveur (le
        // transcodage d'origine n'est jamais tue, verifie empiriquement), donc plus la lecture est
        // avancee, plus la rafale de re-telechargement serait enorme.
        private function onRetryTimer(event:TimerEvent):void {
            var resumeAt:Number = _retryResumeAt;
            _retryResumeAt = 0;
            reconnectAt(resumeAt > 0 ? resumeAt : 0);
        }

        // --- Position et reconnexion apres erreur reseau (il n'y a PAS de seek utilisateur) ---

        // Position logique courante : la cible de la reconnexion en cours le cas echeant, sinon
        // _streamStartOffset + NetStream.time (voir "Suivi du temps" en tete de fichier). Sans
        // flux (avant la premiere lecture), _streamStartOffset vaut la flashvar `startseconds`.
        private function currentPlaybackTime():Number {
            if (_reconnectIntent >= 0) {
                return _reconnectIntent;
            }
            return _stream ? (_streamStartOffset + _stream.time) : _streamStartOffset;
        }

        // Remplace la valeur d'un parametre de requete existant, ou l'ajoute s'il est absent.
        private function replaceOrAppendQueryParam(url:String, paramName:String, value:String):String {
            var pattern:RegExp = new RegExp("([?&])" + paramName + "=[^&]*");
            if (pattern.test(url)) {
                return url.replace(pattern, "$1" + paramName + "=" + value);
            }
            var separator:String = (url.indexOf("?") >= 0) ? "&" : "?";
            return url + separator + paramName + "=" + value;
        }

        // Construit l'URL de reprise apres erreur reseau. Deux parametres a poser :
        // - startTimeTicks : positionne le nouveau transcodage a la position de reprise.
        // - playSessionId : DOIT etre renouvele (voir strategie en tete de fichier : le serveur
        //   identifie le fichier de sortie d'un transcodage par un hash ou startTimeTicks n'entre
        //   pas ; reutiliser l'ancien id ferait reservir l'ancien fichier depuis l'octet 0 --
        //   observe empiriquement, la video repartait du debut).
        // _lastUrl lui-meme reste "propre" (playSessionId et startTimeTicks d'origine) : il sert
        // de modele a chaque reprise.
        private function buildResumeUrl(baseUrl:String, targetSeconds:Number):String {
            var ticks:Number = Math.round(targetSeconds * 10000000);
            var freshSessionId:String = "jellydinosaur" + (new Date()).getTime() + Math.floor(Math.random() * 1000000);
            var withNewSession:String = replaceOrAppendQueryParam(baseUrl, "playSessionId", freshSessionId);
            return replaceOrAppendQueryParam(withNewSession, "startTimeTicks", String(ticks));
        }

        // Rouvre une lecture a la position donnee apres une erreur reseau. Sans risque de fuite de
        // connexion : la connexion precedente est deja morte (c'est l'erreur qui nous amene ici).
        // La conclusion (retour a l'affichage normal) se fait dans onUpdateTick()/onStreamStatus()
        // par avancement du temps, Buffer.Full, ou garde-fou RECONNECT_TIMEOUT_MS.
        private function reconnectAt(target:Number):void {
            _ended = false;
            _reconnectIntent = target;
            _reconnectGoodPolls = 0;
            _reconnectIssuedAt = getTimer();
            _streamStartOffset = target;
            showBufferingIndicator();
            updateTimeText();
            connectAndPlay(buildResumeUrl(_lastUrl, target));
        }

        // Conclut la reconnexion en cours, une fois la lecture reellement repartie sur la nouvelle
        // connexion : NetStream.time (+ _streamStartOffset) redevient la seule source de verite
        // pour la position de lecture.
        private function endReconnect():void {
            _reconnectIntent = -1;
            _reconnectGoodPolls = 0;
            hideBufferingIndicator();
        }

        private function cancelReconnect():void {
            _reconnectIntent = -1;
            _reconnectGoodPolls = 0;
        }

        // --- Boucle de polling (200ms) : tete de telechargement, reconnexion, indicateur ---

        private function onUpdateTick(event:TimerEvent):void {
            if (!_stream) {
                return;
            }
            var now:Number = getTimer();
            var t:Number = _stream.time;

            // Mise a jour de la tete de telechargement observee.
            var head:Number = t + _stream.bufferLength;
            if (head > _maxHeadSeconds) {
                _maxHeadSeconds = head;
            }

            if (_reconnectIntent >= 0) {
                // Reconnexion apres erreur reseau emise. Deux issues normales : la lecture reprend
                // reellement (t avance) -- cas ou l'utilisateur etait en lecture -- ou
                // NetStream.Buffer.Full (voir onStreamStatus()) -- cas ou l'utilisateur etait en
                // pause et t n'avance jamais. RECONNECT_TIMEOUT_MS est un garde-fou si ni l'un ni
                // l'autre ne se produit.
                var reconnectAdvancing:Boolean = t > _lastPolledTime + ADVANCE_EPSILON_S;
                if (reconnectAdvancing) {
                    _reconnectGoodPolls++;
                } else {
                    _reconnectGoodPolls = 0;
                }
                if (_reconnectGoodPolls >= ADVANCE_GOOD_POLLS || (now - _reconnectIssuedAt) > RECONNECT_TIMEOUT_MS) {
                    endReconnect();
                }
            } else if (_rebuffering) {
                var advancing:Boolean = t > _lastPolledTime + ADVANCE_EPSILON_S;
                if (advancing) {
                    _rebufferGoodPolls++;
                } else {
                    _rebufferGoodPolls = 0;
                }
                if (_rebufferGoodPolls >= ADVANCE_GOOD_POLLS || !_isPlaying) {
                    _rebuffering = false;
                    hideBufferingIndicator();
                }
            }

            _lastPolledTime = t;
            updateTimeText();
            updateProgressUI();
        }

        // --- Indicateur de buffering (texte de statut partage avec les messages d'erreur) ---

        private function showBufferingIndicator():void {
            _statusIsBuffering = true;
            _statusText.text = "Buffering...";
            _statusText.visible = true;
            layoutStatus();
        }

        private function hideBufferingIndicator():void {
            if (_statusIsBuffering) {
                _statusIsBuffering = false;
                _statusText.visible = false;
            }
        }

        // --- Construction de la barre de controle (dessin vectoriel, aucune police/icone externe) ---

        private function buildControlBar():void {
            _controlBar = new Sprite();
            addChild(_controlBar);

            _controlBarBg = new Shape();
            _controlBar.addChild(_controlBarBg);

            _playPauseButton = new Sprite();
            _playPauseButton.buttonMode = true;
            _playPauseButton.mouseChildren = false;
            addButtonHit(_playPauseButton);
            _playPauseButton.addEventListener(MouseEvent.CLICK, onPlayPauseClick);
            _controlBar.addChild(_playPauseButton);

            // Barre de progression : pur indicateur, non interactive (pas de seek dans ce lecteur,
            // voir strategie en tete de fichier). mouseEnabled=false pour ne pas capter les clics.
            _progressTrack = new Sprite();
            _progressTrack.mouseEnabled = false;
            _progressTrack.mouseChildren = false;
            _progressBase = new Shape();
            _progressLoaded = new Shape();
            _progressPlayed = new Shape();
            _progressHandle = new Shape();
            _progressTrack.addChild(_progressBase);
            _progressTrack.addChild(_progressLoaded);
            _progressTrack.addChild(_progressPlayed);
            _progressTrack.addChild(_progressHandle);
            _controlBar.addChild(_progressTrack);

            _timeText = createTextField(0xFFFFFF, 11, false);
            _timeText.text = "0:00";
            _controlBar.addChild(_timeText);

            _volumeButton = new Sprite();
            _volumeButton.buttonMode = true;
            _volumeButton.mouseChildren = false;
            addButtonHit(_volumeButton);
            _volumeButton.addEventListener(MouseEvent.CLICK, onVolumeButtonClick);
            _controlBar.addChild(_volumeButton);

            _volumeTrack = new Sprite();
            _volumeTrack.buttonMode = true;
            _volumeHit = new Shape();
            _volumeBase = new Shape();
            _volumeFill = new Shape();
            _volumeHandle = new Shape();
            _volumeTrack.addChild(_volumeHit);
            _volumeTrack.addChild(_volumeBase);
            _volumeTrack.addChild(_volumeFill);
            _volumeTrack.addChild(_volumeHandle);
            _volumeTrack.addEventListener(MouseEvent.MOUSE_DOWN, onVolumeMouseDown);
            _controlBar.addChild(_volumeTrack);

            _fullscreenButton = new Sprite();
            _fullscreenButton.buttonMode = true;
            _fullscreenButton.mouseChildren = false;
            addButtonHit(_fullscreenButton);
            _fullscreenButton.addEventListener(MouseEvent.CLICK, onFullscreenClick);
            _controlBar.addChild(_fullscreenButton);
            drawFullscreenIcon();

            drawPlayPauseIcon();
        }

        // Zone cliquable invisible occupant toute la largeur du bouton et toute la hauteur de la barre
        // de controle, plutot que la seule forme vectorielle dessinee (petite et irreguliere).
        private function addButtonHit(button:Sprite):void {
            var hit:Shape = new Shape();
            hit.graphics.beginFill(0x000000, 0.01);
            var hitY:Number = -(BAR_HEIGHT - BUTTON_SIZE) / 2;
            hit.graphics.drawRect(0, hitY, BUTTON_SIZE, BAR_HEIGHT);
            hit.graphics.endFill();
            button.addChildAt(hit, 0);
        }

        // --- Interactions ---

        private function onPlayPauseClick(event:MouseEvent):void {
            event.stopPropagation();
            togglePlayPause();
        }

        private function onFullscreenClick(event:MouseEvent):void {
            event.stopPropagation();
            toggleFullscreen();
        }

        // Clic simple sur la video/les bandes noires : pause/reprise, differe pour laisser une chance
        // a un second clic de former un double-clic (plein ecran).
        private function onHitAreaClick(event:MouseEvent):void {
            if (_clickTimer && _clickTimer.running) {
                return;
            }
            _clickTimer = new Timer(CLICK_DELAY_MS, 1);
            _clickTimer.addEventListener(TimerEvent.TIMER, onClickTimerFire);
            _clickTimer.start();
        }

        private function onClickTimerFire(event:TimerEvent):void {
            togglePlayPause();
        }

        private function onHitAreaDoubleClick(event:MouseEvent):void {
            if (_clickTimer) {
                _clickTimer.stop();
            }
            toggleFullscreen();
        }

        private function onVolumeButtonClick(event:MouseEvent):void {
            event.stopPropagation();
            if (_isMuted) {
                _isMuted = false;
                _volume = _volumeBeforeMute;
            } else {
                _volumeBeforeMute = _volume;
                _isMuted = true;
            }
            applyVolume();
            updateVolumeUI();
        }

        // Pause/reprise SANS toucher a la connexion : le telechargement continue pendant la pause
        // (comportement progressif de Flash, impossible a interrompre -- voir strategie en tete de
        // fichier), et la reprise est instantanee puisque le tampon a continue de se remplir.
        private function togglePlayPause():void {
            if (!_stream) {
                return;
            }
            _isPlaying = !_isPlaying;
            applyStreamPlayState();
            drawPlayPauseIcon();
            showControlBar();
        }

        private function toggleFullscreen():void {
            if (stage.displayState == StageDisplayState.NORMAL) {
                stage.displayState = StageDisplayState.FULL_SCREEN;
            } else {
                stage.displayState = StageDisplayState.NORMAL;
            }
        }

        private function onFullScreenChange(event:FullScreenEvent):void {
            _isFullscreen = event.fullScreen;
            drawFullscreenIcon();
            layoutAll();
        }

        private function onVolumeMouseDown(event:MouseEvent):void {
            _isDraggingVolume = true;
            stage.addEventListener(MouseEvent.MOUSE_MOVE, onVolumeDrag);
            stage.addEventListener(MouseEvent.MOUSE_UP, onVolumeMouseUp);
            updateVolumeFromMouse();
            showControlBar();
        }

        private function onVolumeDrag(event:MouseEvent):void {
            updateVolumeFromMouse();
        }

        private function onVolumeMouseUp(event:MouseEvent):void {
            stage.removeEventListener(MouseEvent.MOUSE_MOVE, onVolumeDrag);
            stage.removeEventListener(MouseEvent.MOUSE_UP, onVolumeMouseUp);
            _isDraggingVolume = false;
        }

        private function updateVolumeFromMouse():void {
            var localX:Number = _volumeTrack.globalToLocal(new Point(stage.mouseX, stage.mouseY)).x;
            var fraction:Number = localX / VOLUME_WIDTH;
            if (fraction < 0) {
                fraction = 0;
            }
            if (fraction > 1) {
                fraction = 1;
            }
            _volume = fraction;
            // Glisser sur la barre de volume annule le muet.
            _isMuted = false;
            applyVolume();
            updateVolumeUI();
        }

        private function adjustVolume(delta:Number):void {
            _isMuted = false;
            _volume += delta;
            if (_volume < 0) {
                _volume = 0;
            }
            if (_volume > 1) {
                _volume = 1;
            }
            applyVolume();
            updateVolumeUI();
        }

        private function applyVolume():void {
            if (!_soundTransform) {
                return;
            }
            _soundTransform.volume = _isMuted ? 0 : _volume;
            if (_stream) {
                _stream.soundTransform = _soundTransform;
            }
        }

        // Pas de fleches gauche/droite : il n'y a pas de seek dans ce lecteur (voir strategie en
        // tete de fichier).
        private function onKeyDown(event:KeyboardEvent):void {
            if (!_stream) {
                return;
            }
            if (event.keyCode == Keyboard.SPACE) {
                togglePlayPause();
            } else if (event.keyCode == Keyboard.UP) {
                adjustVolume(VOLUME_STEP);
            } else if (event.keyCode == Keyboard.DOWN) {
                adjustVolume(-VOLUME_STEP);
            }
            showControlBar();
        }

        // --- Souris globale : activite (barre de controle) ---

        private function onStageMouseMove(event:MouseEvent):void {
            showControlBar();
        }

        // --- Barre de controle : affichage/masquage ---

        // Reste affichee en permanence quand la video est en pause ; sinon se masque apres
        // HIDE_DELAY_MS d'inactivite. Le curseur souris suit le meme sort que la barre : il
        // reapparait des qu'elle se reaffiche et se masque au meme moment qu'elle.
        private function showControlBar():void {
            _controlBar.visible = true;
            Mouse.show();
            _hideTimer.reset();
            if (_isPlaying) {
                _hideTimer.start();
            }
        }

        private function onHideTimer(event:TimerEvent):void {
            if (_isDraggingVolume || !_isPlaying) {
                _hideTimer.start();
                return;
            }
            _controlBar.visible = false;
            Mouse.hide();
        }

        // --- Mise a jour visuelle ---

        private function updateTimeText():void {
            var current:String = secondsToTimeCode(currentPlaybackTime());
            if (_knownDuration > 0) {
                _timeText.text = current + " / " + secondsToTimeCode(_knownDuration);
            } else {
                _timeText.text = current;
            }
        }

        private function updateProgressUI():void {
            if (_progressWidth <= 0 || !_stream) {
                return;
            }

            if (_knownDuration > 0) {
                // Barre de chargement : tete de telechargement observee sur la connexion courante,
                // remise en position absolue via _streamStartOffset (voir "Suivi du temps" en tete
                // de fichier).
                var head:Number = _streamStartOffset + _maxHeadSeconds;
                if (_estimatedBitrate > 0) {
                    var estimate:Number = _streamStartOffset + (_stream.bytesLoaded * 8) / _estimatedBitrate;
                    if (estimate > head) {
                        head = estimate;
                    }
                }
                if (head > 0) {
                    var loadedFraction:Number = head / _knownDuration;
                    if (loadedFraction > 1) {
                        loadedFraction = 1;
                    }
                    drawProgressLoaded(loadedFraction);
                }

                var playedFraction:Number = currentPlaybackTime() / _knownDuration;
                if (playedFraction > 1) {
                    playedFraction = 1;
                }
                drawProgressPlayed(playedFraction);
            }
        }

        private function updateVolumeUI():void {
            var displayVolume:Number = _isMuted ? 0 : _volume;

            _volumeFill.graphics.clear();
            _volumeFill.graphics.beginFill(COLOR_PLAYED);
            _volumeFill.graphics.drawRect(0, 0, VOLUME_WIDTH * displayVolume, 4);
            _volumeFill.graphics.endFill();
            _volumeFill.y = -2;

            _volumeHandle.graphics.clear();
            _volumeHandle.graphics.beginFill(COLOR_ICON);
            _volumeHandle.graphics.drawCircle(0, 0, 5);
            _volumeHandle.graphics.endFill();
            _volumeHandle.x = VOLUME_WIDTH * displayVolume;

            drawVolumeIcon();
        }

        private function drawProgressLoaded(fraction:Number):void {
            _progressLoaded.graphics.clear();
            _progressLoaded.graphics.beginFill(COLOR_LOADED);
            _progressLoaded.graphics.drawRect(0, 0, _progressWidth * fraction, PROGRESS_HEIGHT);
            _progressLoaded.graphics.endFill();
        }

        // Marqueur de position : triangle (plus lisible qu'un rond). Coordonnees relatives au centre
        // vertical de la barre de progression (le y du Shape est aligne dans layoutControlBar).
        private function drawProgressPlayed(fraction:Number):void {
            _progressPlayed.graphics.clear();
            _progressPlayed.graphics.beginFill(COLOR_PLAYED);
            _progressPlayed.graphics.drawRect(0, 0, _progressWidth * fraction, PROGRESS_HEIGHT);
            _progressPlayed.graphics.endFill();

            var cy:Number = PROGRESS_HEIGHT / 2;
            _progressHandle.graphics.clear();
            _progressHandle.graphics.beginFill(COLOR_ICON);
            _progressHandle.graphics.moveTo(-6, cy - 7);
            _progressHandle.graphics.lineTo(6, cy - 7);
            _progressHandle.graphics.lineTo(0, cy + 5);
            _progressHandle.graphics.lineTo(-6, cy - 7);
            _progressHandle.graphics.endFill();
            _progressHandle.x = _progressWidth * fraction;
        }

        private function drawPlayPauseIcon():void {
            var g:Graphics = _playPauseButton.graphics;
            g.clear();
            g.beginFill(COLOR_ICON);
            if (_isPlaying) {
                g.drawRect(0, 0, 5, BUTTON_SIZE);
                g.drawRect(9, 0, 5, BUTTON_SIZE);
            } else {
                g.moveTo(0, 0);
                g.lineTo(BUTTON_SIZE, BUTTON_SIZE / 2);
                g.lineTo(0, BUTTON_SIZE);
                g.lineTo(0, 0);
            }
            g.endFill();
        }

        private function drawFullscreenIcon():void {
            var g:Graphics = _fullscreenButton.graphics;
            g.clear();
            g.lineStyle(2, COLOR_ICON);
            var s:Number = BUTTON_SIZE;
            var c:Number = 5;
            if (!_isFullscreen) {
                g.moveTo(0, c); g.lineTo(0, 0); g.lineTo(c, 0);
                g.moveTo(s - c, 0); g.lineTo(s, 0); g.lineTo(s, c);
                g.moveTo(s, s - c); g.lineTo(s, s); g.lineTo(s - c, s);
                g.moveTo(c, s); g.lineTo(0, s); g.lineTo(0, s - c);
            } else {
                g.moveTo(c, 0); g.lineTo(0, 0); g.lineTo(0, c);
                g.moveTo(s, c); g.lineTo(s, 0); g.lineTo(s - c, 0);
                g.moveTo(s - c, s); g.lineTo(s, s); g.lineTo(s, s - c);
                g.moveTo(0, s - c); g.lineTo(0, s); g.lineTo(c, s);
            }
            g.lineStyle();
        }

        // Icone haut-parleur ; en mode muet, une croix remplace les ondes sonores.
        private function drawVolumeIcon():void {
            var g:Graphics = _volumeButton.graphics;
            g.clear();
            g.beginFill(COLOR_ICON);
            g.moveTo(0, 6);
            g.lineTo(4, 6);
            g.lineTo(9, 2);
            g.lineTo(9, 16);
            g.lineTo(4, 12);
            g.lineTo(0, 12);
            g.lineTo(0, 6);
            g.endFill();

            var muted:Boolean = _isMuted || _volume <= 0;
            g.lineStyle(2, COLOR_ICON);
            if (muted) {
                g.moveTo(11, 5);
                g.lineTo(17, 13);
                g.moveTo(17, 5);
                g.lineTo(11, 13);
            } else {
                g.moveTo(12, 4);
                g.curveTo(16, 9, 12, 14);
                if (_volume > 0.5) {
                    g.moveTo(14, 1);
                    g.curveTo(19, 9, 14, 17);
                }
            }
            g.lineStyle();
        }

        // --- Statut ---

        private function showStatus(message:String):void {
            _statusIsBuffering = false;
            _statusText.text = message;
            _statusText.visible = true;
            layoutStatus();
        }

        private function hideStatus():void {
            _statusIsBuffering = false;
            _statusText.visible = false;
        }

        // --- Texte (police systeme, pas d'embed de police) ---

        private function createTextField(color:uint, size:int, bold:Boolean):TextField {
            var tf:TextField = new TextField();
            var format:TextFormat = new TextFormat();
            format.color = color;
            format.size = size;
            format.bold = bold;
            format.font = "_sans";
            tf.defaultTextFormat = format;
            tf.autoSize = "left";
            tf.selectable = false;
            tf.mouseEnabled = false;
            return tf;
        }

        private function secondsToTimeCode(seconds:Number):String {
            if (isNaN(seconds) || seconds < 0) {
                seconds = 0;
            }
            seconds = Math.floor(seconds);
            var hours:Number = Math.floor(seconds / 3600);
            var minutes:Number = Math.floor((seconds % 3600) / 60);
            var secs:Number = seconds % 60;
            var minutesStr:String = (minutes < 10 && hours > 0) ? ("0" + minutes) : String(minutes);
            var secsStr:String = (secs < 10) ? ("0" + secs) : String(secs);
            if (hours > 0) {
                return hours + ":" + minutesStr + ":" + secsStr;
            }
            return minutesStr + ":" + secsStr;
        }

        // --- Mise en page ---

        private function drawBackground():void {
            graphics.clear();
            graphics.beginFill(COLOR_BG);
            graphics.drawRect(0, 0, stage.stageWidth, stage.stageHeight);
            graphics.endFill();
        }

        private function layoutHitArea():void {
            _hitArea.graphics.clear();
            _hitArea.graphics.beginFill(0x000000, 0.01);
            _hitArea.graphics.drawRect(0, 0, stage.stageWidth, stage.stageHeight);
            _hitArea.graphics.endFill();
        }

        private function layoutVideo():void {
            var stageW:Number = stage.stageWidth;
            var stageH:Number = stage.stageHeight;

            if (_videoNativeWidth <= 0 || _videoNativeHeight <= 0) {
                _video.x = 0;
                _video.y = 0;
                _video.width = stageW;
                _video.height = stageH;
                return;
            }

            var scale:Number = Math.min(stageW / _videoNativeWidth, stageH / _videoNativeHeight);
            var w:Number = _videoNativeWidth * scale;
            var h:Number = _videoNativeHeight * scale;
            _video.width = w;
            _video.height = h;
            _video.x = Math.round((stageW - w) / 2);
            _video.y = Math.round((stageH - h) / 2);
        }

        private function layoutStatus():void {
            _statusText.x = Math.round((stage.stageWidth - _statusText.width) / 2);
            _statusText.y = Math.round((stage.stageHeight - _statusText.height) / 2);
        }

        private function layoutControlBar():void {
            var stageW:Number = stage.stageWidth;
            var stageH:Number = stage.stageHeight;

            _controlBar.x = 0;
            _controlBar.y = stageH - BAR_HEIGHT;

            _controlBarBg.graphics.clear();
            _controlBarBg.graphics.beginFill(COLOR_BAR_BG, 0.75);
            _controlBarBg.graphics.drawRect(0, 0, stageW, BAR_HEIGHT);
            _controlBarBg.graphics.endFill();

            var midY:Number = BAR_HEIGHT / 2;

            _playPauseButton.x = BAR_PADDING;
            _playPauseButton.y = midY - BUTTON_SIZE / 2;

            _fullscreenButton.x = stageW - BAR_PADDING - BUTTON_SIZE;
            _fullscreenButton.y = _playPauseButton.y;

            _volumeTrack.x = _fullscreenButton.x - BAR_PADDING - 6 - VOLUME_WIDTH;
            _volumeTrack.y = midY;

            _volumeButton.x = _volumeTrack.x - BAR_PADDING - BUTTON_SIZE;
            _volumeButton.y = _playPauseButton.y;

            _volumeHit.graphics.clear();
            _volumeHit.graphics.beginFill(0x000000, 0.01);
            _volumeHit.graphics.drawRect(0, -12, VOLUME_WIDTH, 24);
            _volumeHit.graphics.endFill();

            _volumeBase.graphics.clear();
            _volumeBase.graphics.beginFill(COLOR_TRACK);
            _volumeBase.graphics.drawRect(0, -2, VOLUME_WIDTH, 4);
            _volumeBase.graphics.endFill();

            var timeSlotRight:Number = _volumeButton.x - BAR_PADDING;
            var timeSlotX:Number = timeSlotRight - TIME_SLOT_WIDTH;
            _timeText.x = timeSlotX;
            _timeText.y = Math.round(midY - _timeText.height / 2);

            _progressTrack.x = _playPauseButton.x + BUTTON_SIZE + BAR_PADDING * 1.5;
            _progressTrack.y = midY;
            _progressWidth = timeSlotX - BAR_PADDING - _progressTrack.x;
            if (_progressWidth < 20) {
                _progressWidth = 20;
            }

            _progressBase.graphics.clear();
            _progressBase.graphics.beginFill(COLOR_TRACK);
            _progressBase.graphics.drawRect(0, 0, _progressWidth, PROGRESS_HEIGHT);
            _progressBase.graphics.endFill();
            _progressBase.y = -PROGRESS_HEIGHT / 2;
            _progressLoaded.y = -PROGRESS_HEIGHT / 2;
            _progressPlayed.y = -PROGRESS_HEIGHT / 2;
            _progressHandle.y = -PROGRESS_HEIGHT / 2;

            updateVolumeUI();
            updateProgressUI();
        }

        private function layoutAll():void {
            drawBackground();
            layoutHitArea();
            layoutVideo();
            layoutControlBar();
            layoutStatus();
        }

        private function onStageResize(event:Event):void {
            layoutAll();
        }
    }
}
