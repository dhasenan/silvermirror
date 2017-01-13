module mirror.downloader;

import mirror.common;
import mirror.html_template;
import mirror.config;
import mirror.ratelimit;

import std.datetime;
import std.algorithm;
import std.stdio;
import std.net.curl;
import std.container.rbtree;
import std.uni;
import std.conv;
import std.experimental.logger;
import std.exception : assumeUnique;
import std.string;
import std.digest.sha;
import std.typecons : tuple;
import std.file;

import arsd.dom;
import url : parseURL, URL;

class Downloader
{
    enum MAX_DOWNLOAD = 32 * 1024 * 1024;  // 32 MB

    RedBlackTree!URL urls;
    Map urlMap;
    Config cfg;
    URL base;
    Template templ;
    RateLimiter rateLimiter;
    string queueFile;
    string mapFile;
    string baseDir;

    this(Config config)
    {
        this.cfg = config;
        this.urls = new RedBlackTree!URL;
        this.base = config.baseURL;
        this.templ = config.htmlTemplate;
        this.rateLimiter = config.rateLimiter;
        baseDir = config.path;
        queueFile = baseDir ~ "/queue";
        urlMap = new Map(getMapFile(config));
        // We use mkdirRecurse because it doesn't throw if the directory already exists.
        baseDir.mkdirRecurse();
    }

    void run()
    {
        // Read queue from disk
        urls.clear();
        if (exists(queueFile))
        {
            urls.insert(queueFile.readText().splitLines().map!parseURL);
            writefln("read %s urls from existing queue", urls.length);
        }
        if (urls.empty)
        {
            urls.insert(this.base);
        }

        // Read map from disk
        size_t before = 0;
        if (exists(mapFile))
        {
            urlMap.read();
            writefln("read %s urls from already-downloaded map", urlMap.length);
            before = urlMap.length;
            if (before > cfg.maxFiles)
            {
                return;
            }
        }
        size_t total = before;

        if (!exists(baseDir))
        {
            mkdir(baseDir);
        }

        auto lastWroteQueue = Clock.currTime;
        while (!urls.empty)
        {
            try
            {
                step();
            }
            catch (Throwable e)
            {
                writeln("unexpected error ", e);
            }
            if (urlMap.length >= cfg.maxFiles)
            {
                writefln("requested maximum of %s files downloaded; finished %s", cfg.maxFiles, total);
                break;
            }

            // Flush already-downloaded entries from the queue periodically.
            // This makes things a little nicer if the application exists.
            const now = Clock.currTime;
            if (now - lastWroteQueue > dur!"seconds"(15))
            {
                lastWroteQueue = now;
                auto f = File(queueFile, "w");
                foreach (v; urls)
                {
                    f.writeln(v);
                }
                f.flush;
                f.close;
            }
        }
        writefln("downloaded %s files", urlMap.length - before);
    }

    void step()
    {
        import std.array : Appender;
        if (urls.empty) return;
        auto u = urls.removeAny;
        if (u in urlMap) return;

        auto http = HTTP(u);
        writefln("downloading [#%s; %s remaining] %s", urlMap.length, urls.length, u);
        string contentType;
        Appender!(ubyte[]) buf;
        http.onReceive = (ubyte[] data)
        {
            buf ~= data;
            rateLimiter.limitRate(data.length);
            return data.length;
        };
        bool shutDown = false;
        http.onReceiveHeader = (const(char[]) title, const(char[]) value)
        {
            if (title.toLower == "content-type")
            {
                contentType = value.idup.toLower;
            }
            else if (title.toLower == "content-length")
            {
                auto contentLength = value.to!ulong;
                if (contentLength > cfg.fileSizeCutoff)
                {
                    infof("url %s: canceling download because the content length is %s, which is " ~
                            "greater than the threshold of %s", u, contentLength, cfg.fileSizeCutoff);
                    http.shutdown;
                    shutDown = true;
                }
                else
                {
                    buf.reserve(contentLength);
                }
            }
        };
        http.perform();
        if (shutDown) return;
        contentType = contentType.toLower;
        if (contentType.startsWith("text/html") || contentType.startsWith("application/xhtml+xml"))
        {
            //writeln("content type is text/html; processing as html document");
            processHtml(assumeUnique(cast(char[])buf.data), contentType, u);
        }
        else
        {
            // writeln("content type is ", contentType, "; just saving");
            save(buf.data, contentType, u);
        }
    }

    void processHtml(string html, string contentType, URL url)
    {
        auto doc = new Document(html);
        // We're looking for <link rel=""> and <a href="">.
        // First pass, we skip images and stylesheets.
        // Also, assume it's UTF-8.
        enum attrs = ["img": "src", "a": "href", "link": "href"];
        foreach (k, v; attrs)
        {
            foreach (elem; doc.getElementsByTagName(k))
            {
                auto dest = elem.getAttribute(v).idup;
                auto u = url.resolve(dest);
                // infof("%s resolved %s to %s", url, dest, u);
                elem.setAttribute(v, relPath(u));
                enqueue(u);
            }
        }
        auto s = templ.evaluate(doc, url);
        save(cast(immutable(ubyte)[])s, contentType, url);
    }

    void save(const ubyte[] b, string contentType, URL u)
    {
        import std.digest.sha : sha1Of, toHexString;
        import std.file : write, mkdirRecurse;
        auto hash = sha1Of(b).toHexString().idup;
        // There's a limit of 64k files/directory in ext4.
        // Other filesystems probably the same.
        // Shard things out. While it's not unthinkable to have 16 million files,
        // this should be good out to four billion.
        auto dir = baseDir ~ "/" ~ hash[0..2] ~ "/" ~ hash[2..4];
        dir.mkdirRecurse;
        auto name = dir ~ "/" ~ hash;
        write(name, b);
        urlMap.add(u, name, contentType);
    }

    void enqueue(URL u)
    {
        u.fragment = null;
        if (u.host != base.host)
        {
            infof("url %s: doesn't have base host %s", u, base.host);
            return;
        }
        if (!u.path.startsWith(base.path))
        {
            infof("url %s: doesn't have base path %s", cast(const ubyte[])u.path, cast(const ubyte[])base.path);
            return;
        }
        if (u in urlMap)
        {
            infof("url %s: already saved to a file", u);
            return;
        }
        if (!urls.equalRange(u).empty)
        {
            infof("url %s: already enqueued", u);
            return;
        }
        // writefln("url %s: enqueueing", u);
        urls.insert(u);
        append(queueFile, u.toString ~ "\n");
    }
}
