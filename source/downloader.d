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
import std.regex;
import std.typecons : tuple;
import std.file;

import arsd.dom;
import url : parseURL, URL, URLException;

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
        if (!exists(queueFile) && exists(queueFile ~ ".new"))
        {
            // If both exist, we don't know if we finished writing to the new queue file yet.
            // If only the new one exists, we know we finished writing it.
            std.file.rename(queueFile ~ ".new", queueFile);
        }
        if (exists(queueFile))
        {
            infof("reading queue file");
            auto queueText = queueFile.exists ? queueFile.readText : (queueFile ~ ".new").readText;
            infof("read queuefile text");
            while (queueText.length > 0)
            {
                auto next = queueText.indexOf('\n');
                auto curr = queueText[0..next];
                queueText = queueText[next + 1 .. $];
                try
                {
                    urls.insert(curr.parseURL);
                }
                catch (URLException e)
                {
                    infof("skipping url %s: %s", curr, e);
                }
                
                if (urls.length % 100 == 0)
                {
                    infof("read %s urls so far", urls.length);
                }
            }
            urls.insert(queueFile.readText().splitLines().map!parseURL);
            writefln("read %s urls from existing queue", urls.length);
        }
        if (urls.empty)
        {
            infof("no URLs found; inserting base URL");
            urls.insert(this.base);
        }

        // Read map from disk
        infof("reading URL map from disk");
        urlMap.read();
        writefln("read %s urls from already-downloaded map", urlMap.length);
        if (urlMap.length > cfg.maxFiles)
        {
            return;
        }
        auto before = urlMap.length;

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
                writefln("requested maximum of %s files downloaded; finished %s", cfg.maxFiles, urlMap.length);
                break;
            }

            // Flush already-downloaded entries from the queue periodically.
            // This makes things a little nicer if the application exits.
            const now = Clock.currTime;
            if (now - lastWroteQueue > dur!"seconds"(15))
            {
                lastWroteQueue = now;
                // Write to a new file and rename.
                // This means we're still okay if the application quits in the middle of writing the queue.
                auto tmpQueueFile = queueFile ~ ".new";
                auto tmpOldQueueFile = queueFile ~ ".old";
                auto f = File(tmpQueueFile, "w");
                foreach (v; urls)
                {
                    f.writeln(v);
                }
                f.flush;
                f.close;
                std.file.rename(queueFile, tmpOldQueueFile);
                std.file.rename(tmpQueueFile, queueFile);
                std.file.remove(tmpOldQueueFile);
            }
        }
        writefln("downloaded %s files", urlMap.length - before);
    }

    bool shouldDownload(string url)
    {
        foreach (e; cfg.exclude)
        {
            if (!url.matchFirst(e).empty)
            {
                return false;
            }
        }
        if (cfg.include.length == 0)
        {
            return true;
        }
        foreach (e; cfg.include)
        {
            if (!url.matchFirst(e).empty)
            {
                return true;
            }
        }
        return false;
    }

    void step()
    {
        import std.array : Appender;
        if (urls.empty) return;
        auto u = urls.removeAny;
        if (u in urlMap) return;
        auto s = u.toString;
        if (!shouldDownload(s)) return;
        auto http = HTTP(u.toString);
        writefln("downloading [#%s; %s queued] %s", urlMap.length, urls.length, u);
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
        auto doc = new Document();
        auto idx = contentType.indexOf("charset=");
        string encoding = null;
        if (idx >= 0)
        {
            auto part = contentType[idx..$];
            auto start = part.indexOf('=') + 1;
            encoding = part[start..$];
            auto end = encoding.indexOf(';');
            if (end >= 0)
            {
                encoding = encoding[0..end];
            }
        }
        doc.parse(html, false, false, encoding);
        // We're looking for <link rel=""> and <a href="">.
        // First pass, we skip images and stylesheets.
        // Also, assume it's UTF-8.
        enum attrs = ["img": "src", "a": "href", "link": "href"];
        foreach (k, v; attrs)
        {
            foreach (elem; doc.getElementsByTagName(k))
            {
                auto dest = elem.getAttribute(v).idup.strip;
                try
                {
                    auto u = url.resolve(dest);
                    infof("%s resolved %s to %s", url, dest, u);
                    elem.setAttribute(v, relPath(u));
                    enqueue(u);
                }
                catch (URLException e)
                {
                    // skip this URL
                }
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
        infof("considering url %s", u);
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
        if (!shouldDownload(u.toString))
        {
            infof("url %s: excluded from config", u);
            return;
        }
        // writefln("url %s: enqueueing", u);
        urls.insert(u);
        append(queueFile, u.toString ~ "\n");
    }
}
