Un front-end Jellyfin qui est très léger pour les vieux navigateurs. L'intérêt est de permettre l'utilisation de Jellyfin sur des machines obsolètes avec une bonne expérience engageante.

Contexte du projet :
- JavaScript EcmaScript 3 uniquement
- Le projet doit être entièrement compatible, performant et rapide sur les vieux navigateurs et fonctionner sur les navigateurs du début des années 2000 (de l'ère Windows XP / Macs PowerPC)
- Du HTML très simple, uniquement textuel pour des performances maximales
- Connexion par API key (simple, pas de gestion de session) ou par login/mot de passe
- Les spécifications OpenAPI sont disponibles dans le fichier jellyfin-openapi-stable.json Une aide API est fournie en bas de ce document avec des exemples et est à utiliser en priorité pour savoir comment faire les requêtes.
- Si tu as besoin de credentials pour tester sur un serveur de test, tu dois aller les chercher dans le fichier .env de ce projet, qui est volontairement pas committé
- Ce projet doit fonctionner sur tous les navigateurs qui supportent LocalStorage, donc par exemple à partir de Firefox 3.5

Aide API : 
- Pour passer la clé API, toujours mettre un paramètre de la requête "ApiKey=la clé api". Pas de headers car c'est déprécié.
