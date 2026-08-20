# JellyDinosaur
A no bullshit, very compatible, super fast, and JavaScript ES3 compliant Jellyfin client (front-end).

It is a static < 100kb HTML webpage, which can be uploaded to any HTTP web server or hosted locally. Uploading hls.min.js is necessary only to stream HLS from most modern browsers which lacks native support. The 8kb jellydinosaur-flash-player.swf is a minimalistic AS3 streaming flash client and is useful if your browser has a Flash plug-in.

To host your instance of JellyDinosaur locally and quick, use on the upload folder: python3 -m http.server 20005

You may want to setup this app with an integrated reverse proxy on your LAN which you can do with: node serve-with-proxy.js
*Reverse proxy is especially useful if you need very old operating systems/browsers which lacks modern TLS to access any kind of Jellyfin server requiring SSL.*

## Tech stack
- Pure HTML/ES3 JS (index.html)
- (Optional) A flash AS3 app for streaming. I already compiled this program as an swf in the repo so you don't have to mess with the Flex SDK if you don't intend to modify it.
- (Optional) NodeJS if you want to use the easy SSL escalation reverse proxy script (serve-with-proxy.js) and the build-minify.js minification script I provide
- (Optional) hls.min.js which is loaded on demand to allow HLS streaming. It require pretty modern browsers, it rely on modern APIs and JavaScript.

## Features
- Internationalization (french & english)
- Can login on JellyFin through an API key or a login + password
- Live TV: browse and search the whole channel line-up (paginated server-side, so a 14000-channel IPTV grid stays usable), see what is on right now when the server has a guide, then watch a channel through the same playback options as any other content (direct play, m3u8, mp4, Flash). Direct play sends the channel exactly as broadcast, keeping every audio track and subtitle it carries
- Modern browsers are not excluded and should be happy to use this front-end too with slightly more features but the main aspect you may want it is for performance & its minimalistic approach. Here you won't load megabytes of stuff and executing plenty of javascript for fancy animations and UI stuff & front frameworks.

## What is the minimal configuration
Your browser need to support LocalStorage and ES3 JavaScript. Expect early-2000 browsers to work which covers well the native browsers from the Windows XP/PowerPC Macs era.

Don't expect to get a good experience with streaming even by lowering quality directly from the browser from a 20 years old machine, there's high chances streaming will not work if your browser is too old even if you choose to use the mp4 container ; and using the Flash plug-in often lead to pretty bad performance. Here, JellyDinosaur expect you to download the file or "Copy the stream link" to an adequate application (PowerVLC/XBMC/KODI/VLC/mPlayer) that will do the playback with the best possible performance & reliably.

It is a strength of JellyDinosaur: there's a lot of flexibility in how you want to use it. You may want to use it only to find content & generate valid streaming links, or stream from your browser without ever leaving it.

If your operating system is compatible with PowerVLC, my VLC fork, you may want to NOT use JellyDinosaur at all and use the Jellyfin browser directly integrated into PowerVLC, which is also very fast to load and has the advantage to use gnuTLS so you can connect simply to all HTTPS protected JellyFin servers.

About quality, the default quality on transcoding that will be selected is 480p with the "High quality" preset I provide. I believe most legacy early Intel machines will be happy to decode this. Confirmed smooth on my 2007 GMA950 MacBook Core 2 Duo and looking decently good (feels like DVD quality).

During the early 2000's, the popular & very universal streaming method was to install a Flash plug-in. JellyDinosaur supports this, and even allow you to copy a direct link usable with any standalone Flash projector (though for some reasons, the standalone Flash projector worked pretty bad during my tests, so prefer to use an old browser with the plug-in).

## Recommended browsers on legacy platforms
On MacOS use Basilisk Browser: https://www.basilisk-browser.org/download.html

If you can't run it, use PowerFox: https://powerfox.jazzzny.me/

Those browsers are modern enough so you can stream directly m3u8 h.264 transcoded streams without ever leaving the browser.

# What can't run on very old browsers
- Download bar will be missing before Firefox 6/IE10, though the textual percentage should work & update itself
- Transcoded mp4 download will be unavailable and require ~2010-2011 browsers because xhr.responseType = "blob", URL.createObjectURL are unavailable
- The browser will not save/remember any of your settings over different sessions when local storage is missing. LocalStorage is supported since Chrome 4 (2009), Firefox 3.5 (2009), Opera 10.5 (2010), Safari 4 (2009) on major desktop browsers.
- Some very old browsers are very annoying about cross-domain, so you will need to host JellyDinosaur on the same domain (if you own the JellyFin server) or use the reverse proxy that I provide from a modern computer on your LAN
- Browser need to be JavaScript ES3 (1999) compliant. JellyDinosaur was designed with interactivity so JavaScript ES3 must be available and enabled browser-side.

## What about modern browsers ?
Enjoy m3u8 streaming & a web application that will run very fast and be respectful on your battery if you use a mobile device, I found navigation to be pretty convenient with gestures to zoom & move on the page. It will load very fast.

## Artificial intelligence usage
AI-assisted code using a bit of local Google Gemma (but it was just so slow/limited) and a lot of Claude Code. Sorry, I don't have weeks/months to really master 20 year (ES3 is from 1999) tech and I believe at this point I am proud enough to share that work because I believe it works as great if not best from a production I would had done alone. Also most of the human work there is not even that fun, and just about interacting properly with the Jellyfin API by using old ES3 ways of doing so.

Outside of the code, everything is human efforts, including but not limited to:
- QA testing
- Writing the specs
- Iterating. Plenty of iterating & testing using a real browser & several old machines
- Driving the AI with knowledge of good practices for performance & to fit my quality standards (for example, search here is not going to redraw the page instantly, but instead will wait a bit so if you type several characters at once it will search only once because filtering is a costly operation especially for old machines)
- Some little changes on the code & reviews on what produced the gen-AI (for example I adjusted a lot the qualities presets generated by Claude)
- Writing GitHub commits, documentation, and this README. In english by a french native, so there may be mistake but I want control on what text you are going to see, I don't want to flood you with slop/low quality/out of point info you're not even going to ever read.
- Writing social media posts and answering to comments from the community

## Supporting your work
If you wanna help me to cover the costs of this dev (time spent + API costs for AI tools) and if this app is useful to you, a tip will be greatly apprecied thank you very much: https://www.patreon.com/c/Olsro