/*
 * NppMarkdownPanel — macOS port
 *
 * Real-time Markdown preview panel for Notepad++ macOS.
 * Uses WKWebView with marked.js + highlight.js for rendering.
 * Images with relative paths resolve natively via WKWebView's baseURL.
 *
 * Original Windows plugin by Jens Wollgarten (GPLv2)
 * macOS port: single-file Objective-C++ implementation
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string>
#include <cstring>
#include <dlfcn.h>
#include <dispatch/dispatch.h>

// ═══════════════════════════════════════════════════════════════════════════
//  Constants
// ═══════════════════════════════════════════════════════════════════════════

static const char *PLUGIN_NAME = "Markdown Panel";
static const int NB_FUNC = 8;
static FuncItem funcItem[NB_FUNC];
static NppData nppData;

static const int RENDER_DEBOUNCE_MS = 400;

// ═══════════════════════════════════════════════════════════════════════════
//  Settings
// ═══════════════════════════════════════════════════════════════════════════

struct MarkdownSettings {
    int zoomLevel = 100;
    bool autoShowPanel = false;
    bool syncWithCaret = true;
    bool syncWithFirstVisibleLine = false;
    bool allowAllExtensions = false;
    std::string supportedExtensions = "md,mkd,mdwn,mdown,mdtxt,markdown";
    bool enableMermaid = false;
};

static MarkdownSettings sSettings;

// ═══════════════════════════════════════════════════════════════════════════
//  Plugin state
// ═══════════════════════════════════════════════════════════════════════════

static NSPanel *sPanel = nil;
static WKWebView *sWebView = nil;
static bool sPanelVisible = false;
static bool sTemplateLoaded = false;
static std::string sLastRenderedText;
static std::string sCurrentFilePath;
static std::string sCurrentTempHtmlPath; // Track temp file for cleanup
static dispatch_block_t sPendingRender = nil;
static std::string sResourcesDir;
static std::string sFullTemplate; // HTML template with inlined JS/CSS

// Forward declarations
static void togglePanel();
static void syncWithCaretCmd();
static void syncWithFirstVisibleLineCmd();
static void showSettingsCmd();
static void showHelpCmd();
static void showAboutCmd();
static void exportToHtmlCmd();
static void renderMarkdownDirect();
static void renderMarkdownDeferred();

// ═══════════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════════

static NppHandle getCurScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(h, msg, w, l);
}

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}

static std::string getCurrentFilePath() {
    char buf[4096] = {0};
    npp(NPPM_GETFULLCURRENTPATH, sizeof(buf) - 1, (intptr_t)buf);
    return std::string(buf);
}

static std::string getCurrentExtension() {
    char buf[256] = {0};
    npp(NPPM_GETEXTPART, sizeof(buf) - 1, (intptr_t)buf);
    return std::string(buf);
}

static bool isSupportedExtension() {
    if (sSettings.allowAllExtensions) return true;
    std::string ext = getCurrentExtension();
    if (ext.empty()) return false;
    // Remove leading dot
    if (ext[0] == '.') ext = ext.substr(1);
    // Lowercase
    for (auto &c : ext) c = tolower(c);
    // Check against comma-separated list
    std::string exts = sSettings.supportedExtensions;
    for (auto &c : exts) c = tolower(c);
    size_t pos = 0;
    while (pos < exts.size()) {
        size_t comma = exts.find(',', pos);
        if (comma == std::string::npos) comma = exts.size();
        std::string candidate = exts.substr(pos, comma - pos);
        // Trim whitespace
        while (!candidate.empty() && candidate.front() == ' ') candidate.erase(candidate.begin());
        while (!candidate.empty() && candidate.back() == ' ') candidate.pop_back();
        if (candidate == ext) return true;
        pos = comma + 1;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
//  Resource loading
// ═══════════════════════════════════════════════════════════════════════════

static std::string findResourcesDir() {
    Dl_info info;
    if (dladdr((void *)&findResourcesDir, &info) && info.dli_fname) {
        std::string dylibPath(info.dli_fname);
        size_t lastSlash = dylibPath.rfind('/');
        if (lastSlash != std::string::npos) {
            return dylibPath.substr(0, lastSlash) + "/resources";
        }
    }
    return "";
}

static std::string readFileToString(const std::string &path) {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:path.c_str()]];
        if (!data) return "";
        return std::string((const char *)[data bytes], [data length]);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  HTML template composition
// ═══════════════════════════════════════════════════════════════════════════

static const char *kGitHubMarkdownCSS = R"CSS(
/* GitHub-flavored Markdown CSS — minimal, supports light + dark */
:root {
  --color-fg: #1f2328;
  --color-bg: #ffffff;
  --color-border: #d0d7de;
  --color-code-bg: #f6f8fa;
  --color-blockquote: #59636e;
  --color-link: #0969da;
  --color-heading-border: #d8dee4;
}
@media (prefers-color-scheme: dark) {
  :root {
    --color-fg: #e6edf3;
    --color-bg: #0d1117;
    --color-border: #30363d;
    --color-code-bg: #161b22;
    --color-blockquote: #8b949e;
    --color-link: #58a6ff;
    --color-heading-border: #21262d;
  }
}
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
  font-size: 16px;
  line-height: 1.6;
  color: var(--color-fg);
  background: var(--color-bg);
  max-width: 980px;
  margin: 0 auto;
  padding: 20px 32px 48px;
  word-wrap: break-word;
}
h1, h2, h3, h4, h5, h6 { margin-top: 24px; margin-bottom: 16px; font-weight: 600; line-height: 1.25; }
h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--color-heading-border); }
h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--color-heading-border); }
h3 { font-size: 1.25em; }
h4 { font-size: 1em; }
h5 { font-size: 0.875em; }
h6 { font-size: 0.85em; color: var(--color-blockquote); }
p { margin-top: 0; margin-bottom: 16px; }
a { color: var(--color-link); text-decoration: none; }
a:hover { text-decoration: underline; }
img { max-width: 100%; height: auto; display: block; margin: 16px 0; border-radius: 6px; }
code {
  font-family: 'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace;
  font-size: 85%;
  padding: 0.2em 0.4em;
  background: var(--color-code-bg);
  border-radius: 6px;
}
pre {
  padding: 16px;
  overflow-x: auto;
  font-size: 85%;
  line-height: 1.45;
  background: var(--color-code-bg);
  border-radius: 6px;
  margin-bottom: 16px;
}
pre code { padding: 0; background: transparent; font-size: 100%; }
blockquote {
  margin: 0 0 16px;
  padding: 0 1em;
  color: var(--color-blockquote);
  border-left: 0.25em solid var(--color-border);
}
table { border-collapse: collapse; width: 100%; margin-bottom: 16px; }
th, td { padding: 6px 13px; border: 1px solid var(--color-border); }
th { font-weight: 600; background: var(--color-code-bg); }
tr:nth-child(2n) { background: var(--color-code-bg); }
hr { height: 0.25em; padding: 0; margin: 24px 0; background: var(--color-border); border: 0; border-radius: 2px; }
ul, ol { padding-left: 2em; margin-bottom: 16px; }
li + li { margin-top: 0.25em; }
input[type="checkbox"] { margin-right: 0.5em; }
/* YAML frontmatter displayed as code */
.frontmatter { background: var(--color-code-bg); padding: 12px 16px; border-radius: 6px; margin-bottom: 24px; font-size: 85%; font-family: monospace; color: var(--color-blockquote); border-left: 4px solid var(--color-border); white-space: pre-wrap; }
)CSS";

static void buildTemplate() {
    @autoreleasepool {
        std::string markedJS = readFileToString(sResourcesDir + "/marked.min.js");
        std::string hljsJS = readFileToString(sResourcesDir + "/highlight.min.js");
        std::string hljsLightCSS = readFileToString(sResourcesDir + "/hljs-github.css");
        std::string hljsDarkCSS = readFileToString(sResourcesDir + "/hljs-github-dark.css");

        if (markedJS.empty()) {
            NSLog(@"[MarkdownPanel] ERROR: marked.min.js not found in %s", sResourcesDir.c_str());
            return;
        }

        // Check for optional mermaid
        std::string mermaidJS;
        if (sSettings.enableMermaid) {
            mermaidJS = readFileToString(sResourcesDir + "/mermaid.min.js");
        }

        std::string html = "<!DOCTYPE html>\n<html><head>\n<meta charset=\"utf-8\">\n";
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n";

        // CSS
        html += "<style>\n";
        html += kGitHubMarkdownCSS;
        html += "\n</style>\n";
        // highlight.js light CSS (default)
        html += "<style media=\"(prefers-color-scheme: light)\">\n" + hljsLightCSS + "\n</style>\n";
        html += "<style media=\"(prefers-color-scheme: dark)\">\n" + hljsDarkCSS + "\n</style>\n";

        // Zoom
        html += "<style>body { zoom: " + std::to_string(sSettings.zoomLevel) + "%; }</style>\n";

        // JS libraries
        html += "<script>\n" + markedJS + "\n</script>\n";
        if (!hljsJS.empty()) {
            html += "<script>\n" + hljsJS + "\n</script>\n";
        }
        if (!mermaidJS.empty()) {
            html += "<script>\n" + mermaidJS + "\n</script>\n";
        }

        // Application JS
        html += R"HTML(
<script>
// Render function called from native code.
// Uses marked.js defaults for ALL rendering (no custom renderer overrides
// that might break across marked.js versions), then post-processes the HTML
// to add block IDs for scroll sync and apply syntax highlighting.
function renderMarkdown(md) {
  // Handle YAML frontmatter
  var content = md;
  var frontmatter = '';
  if (md.startsWith('---\n') || md.startsWith('---\r\n')) {
    var endIdx = md.indexOf('\n---', 3);
    if (endIdx === -1) endIdx = md.indexOf('\r\n---', 3);
    if (endIdx > 0) {
      var fmEnd = md.indexOf('\n', endIdx + 1);
      if (fmEnd === -1) fmEnd = md.length;
      frontmatter = md.substring(4, endIdx).trim();
      content = md.substring(fmEnd + 1);
    }
  }

  var html = '';
  if (frontmatter) {
    html += '<div class="frontmatter">' +
      frontmatter.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;') +
      '</div>\n';
  }

  // Render with marked.js defaults (handles images, code, tables, etc.)
  html += marked.parse(content, {gfm: true, breaks: false});

  // Post-process: add sequential IDs to block elements for scroll sync
  var blockIdx = 0;
  html = html.replace(/<(h[1-6]|p|pre|ul|ol|table|blockquote|hr)([\s>])/g,
    function(match, tag, after) {
      return '<' + tag + ' id="block-' + (blockIdx++) + '"' + after;
    });

  document.getElementById('content').innerHTML = html;

  // Syntax highlighting: let highlight.js find and process all code blocks
  if (typeof hljs !== 'undefined') {
    document.querySelectorAll('pre code').forEach(function(el) {
      hljs.highlightElement(el);
    });
  }

  // Re-run mermaid for ```mermaid code blocks if available
  if (typeof mermaid !== 'undefined') {
    document.querySelectorAll('pre code.language-mermaid').forEach(function(el) {
      var pre = el.parentNode;
      pre.classList.add('mermaid');
      pre.innerHTML = el.textContent;
    });
    try { mermaid.run({querySelector: '.mermaid'}); } catch(e) {}
  }

  window._totalLines = md.split('\n').length;
}

// Scroll sync: proportional by document height (smooth, no jumping)
var _scrollTimer = null;
function scrollToLine(lineNo) {
  if (!window._totalLines || window._totalLines <= 1) return;
  // Cancel any pending scroll to avoid fighting
  if (_scrollTimer) { clearTimeout(_scrollTimer); }
  _scrollTimer = setTimeout(function() {
    var ratio = Math.max(0, Math.min(1, lineNo / (window._totalLines - 1)));
    var maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    var targetY = Math.round(ratio * maxScroll);
    window.scrollTo({top: targetY, behavior: 'smooth'});
    _scrollTimer = null;
  }, 50);
}

// Scroll to top
function scrollToTop() {
  window.scrollTo({top: 0, behavior: 'smooth'});
}

// Initialize mermaid if available
if (typeof mermaid !== 'undefined') {
  mermaid.initialize({startOnLoad: false, theme: 'default'});
}
</script>
</head>
<body>
<div id="content"><p style="color: #888; font-style: italic;">Markdown preview will appear here...</p></div>
</body>
</html>
)HTML";

        sFullTemplate = html;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Settings persistence
// ═══════════════════════════════════════════════════════════════════════════

static std::string getConfigPath() {
    char buf[1024] = {};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR,
                         (uintptr_t)sizeof(buf), (intptr_t)buf);
    NSString *dir;
    if (buf[0] != '\0') {
        dir = [NSString stringWithUTF8String:buf];
    } else {
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@".notepad++"];
    }
    return std::string([dir UTF8String]) + "/NppMarkdownPanel.json";
}

static void loadSettings() {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:getConfigPath().c_str()];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!dict) return;

        NSNumber *v;
        NSString *s;
        if ((v = dict[@"zoomLevel"])) sSettings.zoomLevel = [v intValue];
        if ((v = dict[@"autoShowPanel"])) sSettings.autoShowPanel = [v boolValue];
        if ((v = dict[@"syncWithCaret"])) sSettings.syncWithCaret = [v boolValue];
        if ((v = dict[@"syncWithFirstVisibleLine"])) sSettings.syncWithFirstVisibleLine = [v boolValue];
        if ((v = dict[@"allowAllExtensions"])) sSettings.allowAllExtensions = [v boolValue];
        if ((s = dict[@"supportedExtensions"])) sSettings.supportedExtensions = [s UTF8String];
        if ((v = dict[@"enableMermaid"])) sSettings.enableMermaid = [v boolValue];
    }
}

static void saveSettings() {
    @autoreleasepool {
        NSDictionary *dict = @{
            @"zoomLevel": @(sSettings.zoomLevel),
            @"autoShowPanel": @(sSettings.autoShowPanel),
            @"syncWithCaret": @(sSettings.syncWithCaret),
            @"syncWithFirstVisibleLine": @(sSettings.syncWithFirstVisibleLine),
            @"allowAllExtensions": @(sSettings.allowAllExtensions),
            @"supportedExtensions": @(sSettings.supportedExtensions.c_str()),
            @"enableMermaid": @(sSettings.enableMermaid),
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                      options:NSJSONWritingPrettyPrinted error:nil];
        if (data) {
            [data writeToFile:[NSString stringWithUTF8String:getConfigPath().c_str()] atomically:YES];
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  WKWebView panel
// ═══════════════════════════════════════════════════════════════════════════

@interface MarkdownNavigationDelegate : NSObject <WKNavigationDelegate>
@end

@implementation MarkdownNavigationDelegate
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    // Allow initial loads and JS-triggered navigations
    if (action.navigationType == WKNavigationTypeOther ||
        action.navigationType == WKNavigationTypeReload) {
        handler(WKNavigationActionPolicyAllow);
        return;
    }
    // Open external links in the default browser
    NSURL *url = action.request.URL;
    if (url && ([@"http" isEqualToString:url.scheme] || [@"https" isEqualToString:url.scheme])) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
    handler(WKNavigationActionPolicyCancel);
}
@end

static MarkdownNavigationDelegate *sNavDelegate = nil;

static void createPanel() {
    if (sPanel) return;

    @autoreleasepool {
        NSRect frame = NSMakeRect(100, 100, 500, 700);
        sPanel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskTitled |
                                                      NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskResizable |
                                                      NSWindowStyleMaskUtilityWindow
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
        [sPanel setTitle:@"Markdown Panel"];
        [sPanel setFloatingPanel:YES];
        [sPanel setHidesOnDeactivate:NO];
        [sPanel setReleasedWhenClosed:NO];
        [sPanel setLevel:NSFloatingWindowLevel - 1]; // Below floating but above normal

        // Handle panel close via the X button
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification
                       object:sPanel
                        queue:nil
                   usingBlock:^(NSNotification *note) {
                       sPanelVisible = false;
                       nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                                            (uintptr_t)funcItem[0]._cmdID, 0);
                   }];

        // WKWebView with file access
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.defaultWebpagePreferences.allowsContentJavaScript = YES;

        sWebView = [[WKWebView alloc] initWithFrame:sPanel.contentView.bounds configuration:config];
        sWebView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        sNavDelegate = [[MarkdownNavigationDelegate alloc] init];
        sWebView.navigationDelegate = sNavDelegate;

        [sPanel.contentView addSubview:sWebView];

        // Position to the right of the main window
        NSWindow *mainWin = [NSApp mainWindow];
        if (mainWin) {
            NSRect mainFrame = mainWin.frame;
            NSRect panelFrame = sPanel.frame;
            panelFrame.origin.x = NSMaxX(mainFrame) + 4;
            panelFrame.origin.y = mainFrame.origin.y;
            panelFrame.size.height = mainFrame.size.height;
            [sPanel setFrame:panelFrame display:NO];
        }
    }
}

static void loadTemplateIntoWebView() {
    if (!sWebView || sFullTemplate.empty()) return;

    @autoreleasepool {
        // Write the HTML into the SAME directory as the markdown file so that
        // relative image paths (e.g., "subdir/image.png") resolve naturally.
        // WKWebView's <base> tag does NOT work for file:// image resolution,
        // so the HTML file must physically be in the right directory.
        std::string fp = getCurrentFilePath();
        NSString *markdownDir = nil;
        if (!fp.empty()) {
            markdownDir = [[NSString stringWithUTF8String:fp.c_str()] stringByDeletingLastPathComponent];
        }

        NSString *tmpPath;
        NSURL *accessURL;
        if (markdownDir && markdownDir.length > 0) {
            // Hidden temp file alongside the markdown file
            tmpPath = [markdownDir stringByAppendingPathComponent:@".npp-md-preview.html"];
            accessURL = [NSURL fileURLWithPath:markdownDir];
        } else {
            // Fallback for unsaved files — use temp directory
            tmpPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"npp-md-preview.html"];
            accessURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
        }

        // Clean up previous temp file if it was in a different directory
        if (!sCurrentTempHtmlPath.empty()) {
            NSString *oldPath = [NSString stringWithUTF8String:sCurrentTempHtmlPath.c_str()];
            [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
        }
        sCurrentTempHtmlPath = std::string([tmpPath UTF8String]);

        NSString *htmlStr = [NSString stringWithUTF8String:sFullTemplate.c_str()];
        [htmlStr writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSURL *fileURL = [NSURL fileURLWithPath:tmpPath];
        [sWebView loadFileURL:fileURL allowingReadAccessToURL:accessURL];

        sTemplateLoaded = true;
        sLastRenderedText.clear();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Markdown rendering
// ═══════════════════════════════════════════════════════════════════════════

static std::string getEditorText() {
    NppHandle h = getCurScintilla();
    if (!h) return "";
    intptr_t len = sci(h, SCI_GETLENGTH);
    if (len <= 0) return "";
    if (len > 5 * 1024 * 1024) return ""; // Skip files > 5MB

    std::string buf(len + 1, '\0');
    sci(h, SCI_GETTEXT, (uintptr_t)(len + 1), (intptr_t)buf.data());
    buf.resize(len);
    return buf;
}

static void renderMarkdownDirect() {
    if (!sPanelVisible || !sWebView) return;
    if (!isSupportedExtension()) {
        // Show "not a markdown file" message
        [sWebView evaluateJavaScript:
            @"document.getElementById('content').innerHTML = "
            "'<p style=\"color:#888;font-style:italic;\">Current file is not a Markdown file.</p>';"
            completionHandler:nil];
        return;
    }

    std::string text = getEditorText();
    if (text == sLastRenderedText) return; // No change
    sLastRenderedText = text;

    // Check if baseURL needs updating (file path changed)
    std::string newPath = getCurrentFilePath();
    if (newPath != sCurrentFilePath) {
        sCurrentFilePath = newPath;
        // Full reload with new baseURL
        loadTemplateIntoWebView();
        // Schedule the render after page loads
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            renderMarkdownDirect();
        });
        return;
    }

    @autoreleasepool {
        // Escape the markdown text for JavaScript string injection
        NSString *nsText = [NSString stringWithUTF8String:text.c_str()];
        if (!nsText) nsText = @"";

        // Use JSON encoding to safely escape the string
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[nsText] options:0 error:nil];
        if (!jsonData) return;
        NSString *jsonArray = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        // Extract the string from the JSON array: ["text"] → text
        // Remove leading [ and trailing ]
        NSString *jsonEscaped = [jsonArray substringWithRange:NSMakeRange(1, jsonArray.length - 2)];

        NSString *js = [NSString stringWithFormat:@"renderMarkdown(%@);", jsonEscaped];
        [sWebView evaluateJavaScript:js completionHandler:nil];
    }
}

static void renderMarkdownDeferred() {
    if (!sPanelVisible) return;
    if (sPendingRender) {
        dispatch_block_cancel(sPendingRender);
        sPendingRender = nil;
    }
    sPendingRender = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        renderMarkdownDirect();
        sPendingRender = nil;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RENDER_DEBOUNCE_MS * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), sPendingRender);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Scroll synchronization
// ═══════════════════════════════════════════════════════════════════════════

static intptr_t sLastSyncLine = -1;
static dispatch_block_t sPendingScroll = nil;

static void syncScroll() {
    if (!sPanelVisible || !sWebView) return;

    NppHandle h = getCurScintilla();
    if (!h) return;

    intptr_t lineNo = 0;
    if (sSettings.syncWithCaret) {
        intptr_t pos = sci(h, SCI_GETCURRENTPOS);
        lineNo = sci(h, SCI_LINEFROMPOSITION, (uintptr_t)pos);
    } else if (sSettings.syncWithFirstVisibleLine) {
        lineNo = sci(h, SCI_GETFIRSTVISIBLELINE);
        lineNo = sci(h, SCI_DOCLINEFROMVISIBLE, (uintptr_t)lineNo);
    } else {
        return;
    }

    if (lineNo == sLastSyncLine) return;
    sLastSyncLine = lineNo;

    // Debounce scroll commands — SCN_UPDATEUI fires very frequently
    if (sPendingScroll) {
        dispatch_block_cancel(sPendingScroll);
        sPendingScroll = nil;
    }
    intptr_t capturedLine = lineNo;
    sPendingScroll = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        @autoreleasepool {
            NSString *js = [NSString stringWithFormat:@"scrollToLine(%ld);", (long)capturedLine];
            [sWebView evaluateJavaScript:js completionHandler:nil];
        }
        sPendingScroll = nil;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), sPendingScroll);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Menu commands
// ═══════════════════════════════════════════════════════════════════════════

static void togglePanel() {
    if (!sPanel) {
        createPanel();
        buildTemplate();
    }

    sPanelVisible = !sPanelVisible;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[0]._cmdID, sPanelVisible ? 1 : 0);

    if (sPanelVisible) {
        [sPanel orderFront:nil];
        sCurrentFilePath.clear(); // Force baseURL update
        sLastRenderedText.clear();
        loadTemplateIntoWebView();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            renderMarkdownDirect();
        });
    } else {
        [sPanel orderOut:nil];
    }
}

static void syncWithCaretCmd() {
    sSettings.syncWithCaret = !sSettings.syncWithCaret;
    if (sSettings.syncWithCaret) sSettings.syncWithFirstVisibleLine = false;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[2]._cmdID, sSettings.syncWithCaret ? 1 : 0);
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[3]._cmdID, sSettings.syncWithFirstVisibleLine ? 1 : 0);
    saveSettings();
    sLastSyncLine = -1;
    if (sSettings.syncWithCaret) syncScroll();
}

static void syncWithFirstVisibleLineCmd() {
    sSettings.syncWithFirstVisibleLine = !sSettings.syncWithFirstVisibleLine;
    if (sSettings.syncWithFirstVisibleLine) sSettings.syncWithCaret = false;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[2]._cmdID, sSettings.syncWithCaret ? 1 : 0);
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[3]._cmdID, sSettings.syncWithFirstVisibleLine ? 1 : 0);
    saveSettings();
    sLastSyncLine = -1;
    if (sSettings.syncWithFirstVisibleLine) syncScroll();
}

static void exportToHtmlCmd() {
    if (!sPanelVisible || !sWebView) return;
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"html"]];
        panel.nameFieldStringValue = @"preview.html";

        if ([panel runModal] == NSModalResponseOK && panel.URL) {
            [sWebView evaluateJavaScript:@"document.documentElement.outerHTML"
                       completionHandler:^(id result, NSError *error) {
                if ([result isKindOfClass:[NSString class]]) {
                    NSString *html = (NSString *)result;
                    [html writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }];
        }
    }
}

static void showSettingsCmd() {
    @autoreleasepool {
        NSPanel *dlg = [[NSPanel alloc] initWithContentRect:NSMakeRect(200, 200, 420, 380)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered defer:NO];
        [dlg setTitle:@"Markdown Panel Settings"];
        NSView *cv = [dlg contentView];
        CGFloat y = 340;

        // Zoom
        NSTextField *zoomLabel = [NSTextField labelWithString:@"Zoom Level:"];
        zoomLabel.frame = NSMakeRect(20, y, 100, 20);
        [cv addSubview:zoomLabel];
        NSTextField *zoomField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, y, 60, 24)];
        zoomField.stringValue = [NSString stringWithFormat:@"%d", sSettings.zoomLevel];
        [cv addSubview:zoomField];
        NSTextField *zoomPct = [NSTextField labelWithString:@"%"];
        zoomPct.frame = NSMakeRect(195, y, 20, 20);
        [cv addSubview:zoomPct];
        y -= 35;

        // Extensions
        NSTextField *extLabel = [NSTextField labelWithString:@"Supported extensions:"];
        extLabel.frame = NSMakeRect(20, y, 140, 20);
        [cv addSubview:extLabel];
        NSTextField *extField = [[NSTextField alloc] initWithFrame:NSMakeRect(170, y, 220, 24)];
        extField.stringValue = @(sSettings.supportedExtensions.c_str());
        [cv addSubview:extField];
        y -= 35;

        // Checkboxes
        NSButton *allExtCheck = [NSButton checkboxWithTitle:@"Allow all file extensions" target:nil action:nil];
        allExtCheck.frame = NSMakeRect(20, y, 350, 20);
        allExtCheck.state = sSettings.allowAllExtensions ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:allExtCheck];
        y -= 28;

        NSButton *autoShowCheck = [NSButton checkboxWithTitle:@"Automatically show panel for supported files" target:nil action:nil];
        autoShowCheck.frame = NSMakeRect(20, y, 350, 20);
        autoShowCheck.state = sSettings.autoShowPanel ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:autoShowCheck];
        y -= 28;

        NSButton *caretCheck = [NSButton checkboxWithTitle:@"Synchronize with caret position" target:nil action:nil];
        caretCheck.frame = NSMakeRect(20, y, 350, 20);
        caretCheck.state = sSettings.syncWithCaret ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:caretCheck];
        y -= 28;

        NSButton *firstLineCheck = [NSButton checkboxWithTitle:@"Synchronize with first visible line" target:nil action:nil];
        firstLineCheck.frame = NSMakeRect(20, y, 350, 20);
        firstLineCheck.state = sSettings.syncWithFirstVisibleLine ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:firstLineCheck];
        y -= 28;

        NSButton *mermaidCheck = [NSButton checkboxWithTitle:@"Enable Mermaid diagram rendering" target:nil action:nil];
        mermaidCheck.frame = NSMakeRect(20, y, 350, 20);
        mermaidCheck.state = sSettings.enableMermaid ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:mermaidCheck];
        y -= 45;

        // Save button
        NSButton *saveBtn = [NSButton buttonWithTitle:@"Save" target:NSApp action:@selector(stopModal)];
        saveBtn.frame = NSMakeRect(310, y, 80, 30);
        saveBtn.keyEquivalent = @"\r";
        [cv addSubview:saveBtn];

        // Close observer
        id observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification object:dlg queue:nil
                   usingBlock:^(NSNotification *n) { [NSApp stopModal]; }];

        [NSApp runModalForWindow:dlg];
        [[NSNotificationCenter defaultCenter] removeObserver:observer];

        // Read values
        bool needsReload = false;
        int newZoom = [zoomField.stringValue intValue];
        if (newZoom < 50) newZoom = 50;
        if (newZoom > 300) newZoom = 300;
        if (newZoom != sSettings.zoomLevel) { sSettings.zoomLevel = newZoom; needsReload = true; }
        sSettings.supportedExtensions = [extField.stringValue UTF8String];
        sSettings.allowAllExtensions = allExtCheck.state == NSControlStateValueOn;
        sSettings.autoShowPanel = autoShowCheck.state == NSControlStateValueOn;
        sSettings.syncWithCaret = caretCheck.state == NSControlStateValueOn;
        sSettings.syncWithFirstVisibleLine = firstLineCheck.state == NSControlStateValueOn;
        bool newMermaid = mermaidCheck.state == NSControlStateValueOn;
        if (newMermaid != sSettings.enableMermaid) { sSettings.enableMermaid = newMermaid; needsReload = true; }

        // Update checkmarks
        npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[2]._cmdID, sSettings.syncWithCaret ? 1 : 0);
        npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[3]._cmdID, sSettings.syncWithFirstVisibleLine ? 1 : 0);

        saveSettings();
        [dlg close];

        if (needsReload && sPanelVisible) {
            buildTemplate();
            sCurrentFilePath.clear();
            sLastRenderedText.clear();
            loadTemplateIntoWebView();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ renderMarkdownDirect(); });
        }
    }
}

static void showHelpCmd() {
    // Open the bundled help.md file in Notepad++ (and show the preview panel)
    static std::string sHelpPath;
    sHelpPath = sResourcesDir + "/help.md";
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:[NSString stringWithUTF8String:sHelpPath.c_str()]]) {
            nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)sHelpPath.c_str());
            // Auto-show the panel so the user sees the rendered help
            if (!sPanelVisible) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{ togglePanel(); });
            }
        } else {
            [[NSWorkspace sharedWorkspace] openURL:
                [NSURL URLWithString:@"https://github.com/notepad-plus-plus-mac/NppMarkdownPanel"]];
        }
    }
}

static void showAboutCmd() {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Markdown Panel";
        alert.informativeText =
            @"Markdown Panel for Notepad++ (macOS port)\n\n"
            "Real-time Markdown preview with GitHub-flavored rendering.\n\n"
            "Features:\n"
            "- Live preview as you type\n"
            "- Syntax highlighting for code blocks\n"
            "- Relative image support\n"
            "- Dark mode support\n"
            "- Scroll synchronization\n"
            "- Export to HTML\n"
            "- YAML frontmatter display\n"
            "- Mermaid diagram support (optional)\n\n"
            "Rendering: marked.js + highlight.js in WKWebView\n\n"
            "Original Windows plugin by Jens Wollgarten (GPLv2)\n"
            "macOS port using native WebKit rendering.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plugin exports
// ═══════════════════════════════════════════════════════════════════════════

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    sResourcesDir = findResourcesDir();
    loadSettings();

    int idx = 0;
    auto addItem = [&](const char *name, PFUNCPLUGINCMD func) {
        strlcpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        funcItem[idx]._pFunc = func;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };
    auto addSep = [&]() {
        funcItem[idx]._itemName[0] = '\0';
        funcItem[idx]._pFunc = nullptr;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };

    addItem("Toggle Markdown Panel",                togglePanel);        // 0
    addSep();                                                             // 1
    addItem("Synchronize with caret position",      syncWithCaretCmd);   // 2
    addItem("Synchronize with first visible line",  syncWithFirstVisibleLineCmd); // 3
    addSep();                                                             // 4
    addItem("Settings",                             showSettingsCmd);     // 5
    addItem("Help",                                 showHelpCmd);         // 6
    addItem("About",                                showAboutCmd);        // 7

    // Set initial checkmarks for sync modes
    funcItem[2]._init2Check = sSettings.syncWithCaret;
    funcItem[3]._init2Check = sSettings.syncWithFirstVisibleLine;
}

extern "C" NPP_EXPORT const char *getName() {
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION:
            // Register toolbar icon — host looks for toolbar.png in the plugin's directory
            nppData._sendMessage(nppData._nppHandle, NPPM_ADDTOOLBARICON_FORDARKMODE,
                                 (uintptr_t)funcItem[0]._cmdID,
                                 (intptr_t)"toolbar.png");
            break;

        case NPPN_READY:
            // Auto-show if configured
            if (sSettings.autoShowPanel && isSupportedExtension()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!sPanelVisible) togglePanel();
                });
            }
            break;

        case NPPN_BUFFERACTIVATED:
            if (sPanelVisible) {
                sLastRenderedText.clear();
                sCurrentFilePath.clear();
                sLastSyncLine = -1;
                renderMarkdownDeferred();

                // Auto-show/hide based on extension
                if (sSettings.autoShowPanel) {
                    // Panel is visible — just re-render, the render function
                    // handles "not a markdown file" display
                }
            }
            break;

        case SCN_MODIFIED:
            if (sPanelVisible && (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
                renderMarkdownDeferred();
            }
            break;

        case SCN_UPDATEUI:
            if (sPanelVisible) {
                syncScroll();
            }
            break;

        case NPPN_SHUTDOWN:
            saveSettings();
            // Clean up temp preview file
            if (!sCurrentTempHtmlPath.empty()) {
                [[NSFileManager defaultManager]
                    removeItemAtPath:[NSString stringWithUTF8String:sCurrentTempHtmlPath.c_str()]
                               error:nil];
                sCurrentTempHtmlPath.clear();
            }
            if (sPanel) {
                [sPanel close];
                sPanel = nil;
                sWebView = nil;
                sNavDelegate = nil;
            }
            break;

        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
