// Script de build (Node.js) : génère une version minifiée de index.html dans upload/.
// N'est PAS exécuté par les navigateurs, c'est un outil de build local uniquement.
//
// Approche volontairement conservative pour ne jamais casser la compatibilité ES3 :
// - Le JS est minifié avec Terser en ciblant explicitement ecma:5, sans aucune transformation
//   qui pourrait introduire une syntaxe plus récente (flèches, spread, etc. -- de toute façon
//   absentes du code source, qui est déjà strictement ES3).
// - Le CSS et le HTML autour ne sont minifiés que par un simple compactage des espaces/retours
//   à la ligne superflus (le navigateur les collapse de toute façon en un seul espace lors du
//   rendu, donc cette transformation ne change rien visuellement) et suppression des commentaires
//   CSS -- pas de minifieur HTML "agressif" qui pourrait toucher à des détails structurels.

var fs = require("fs");
var path = require("path");
var childProcess = require("child_process");

var ROOT = __dirname;
var SRC = path.join(ROOT, "index.html");
var OUT_DIR = path.join(ROOT, "upload");

var html = fs.readFileSync(SRC, "utf8");

function extractBlock(source, tagName) {
    var re = new RegExp("<" + tagName + "(\\s[^>]*)?>([\\s\\S]*?)</" + tagName + ">");
    var m = source.match(re);
    if (!m) {
        throw new Error("Bloc <" + tagName + "> introuvable dans index.html");
    }
    return { full: m[0], attrs: m[1] || "", content: m[2] };
}

// --- 1. Extraction du <script> et minification JS avec Terser ---
var scriptBlock = extractBlock(html, "script");
var jsSrcPath = path.join(ROOT, ".build-src.js");
var jsOutPath = path.join(ROOT, ".build-out.js");
fs.writeFileSync(jsSrcPath, scriptBlock.content, "utf8");

var terserArgs = [
    "--yes", "terser@5",
    jsSrcPath,
    "--compress", "ecma=5,arrows=false,arguments=false,typeofs=false",
    "--mangle",
    "--output", jsOutPath
];
var terserResult = childProcess.spawnSync("npx", terserArgs, { stdio: "inherit" });
if (terserResult.status !== 0) {
    throw new Error("Terser a échoué (code " + terserResult.status + ")");
}
var minifiedJs = fs.readFileSync(jsOutPath, "utf8").replace(/\s+$/, "");

// --- 2. Minification simple du <style> (compactage espaces + suppression commentaires) ---
var styleBlock = extractBlock(html, "style");
var minifiedCss = styleBlock.content
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/[ \t\r\n]+/g, " ")
    .replace(/\s*([{}:;,])\s*/g, "$1")
    .replace(/;}/g, "}")
    .replace(/^ +| +$/g, "");

// --- 3. Reconstruction du HTML avec compactage des espaces (hors <script>/<style>) ---
var withoutScript = html.slice(0, html.indexOf(scriptBlock.full))
    + "SCRIPT"
    + html.slice(html.indexOf(scriptBlock.full) + scriptBlock.full.length);
var withoutStyle = withoutScript.slice(0, withoutScript.indexOf(styleBlock.full))
    + "STYLE"
    + withoutScript.slice(withoutScript.indexOf(styleBlock.full) + styleBlock.full.length);

// Note : on ne supprime PAS l'espace entre balises adjacentes ("> <" -> "><") : le fichier
// contient de nombreux cas comme "</span> <input ...>" où cet espace est un vrai espace visuel
// entre un label et son champ, et le retirer collerait visuellement les deux éléments.
var minifiedShell = withoutStyle
    .replace(/[ \t\r\n]+/g, " ")
    .replace(/^ +| +$/g, "");

var finalHtml = minifiedShell
    .replace("STYLE", "<style>" + minifiedCss + "</style>")
    .replace("SCRIPT", "<script>" + minifiedJs + "</script>");

// --- 4. Écriture des fichiers dans upload/ ---
if (!fs.existsSync(OUT_DIR)) {
    fs.mkdirSync(OUT_DIR);
}
fs.writeFileSync(path.join(OUT_DIR, "index.html"), finalHtml, "utf8");
fs.copyFileSync(path.join(ROOT, "jellydinosaur-flash-player.swf"), path.join(OUT_DIR, "jellydinosaur-flash-player.swf"));
fs.copyFileSync(path.join(ROOT, "hls.min.js"), path.join(OUT_DIR, "hls.min.js"));

fs.unlinkSync(jsSrcPath);
fs.unlinkSync(jsOutPath);

var originalSize = Buffer.byteLength(html, "utf8");
var finalSize = Buffer.byteLength(finalHtml, "utf8");
console.log("index.html : " + originalSize + " -> " + finalSize + " octets (" + Math.round((1 - finalSize / originalSize) * 100) + "% de réduction)");
console.log("upload/ généré avec succès.");
