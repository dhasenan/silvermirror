module mirror.downloader;

import mirror.common;
import mirror.html_template;

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
    URL base;
    Template templ;
    string queueFile;
    string mapFile;
    string baseDir;

    this(string base, Template templ)
    {
        this.urls = new RedBlackTree!URL;
        this.base = base.parseURL;
        baseDir = getBaseDir(base);
        queueFile = "queue_" ~ baseDir;
        urlMap = new Map(getMapFile(base));
        this.templ = templ;
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
        }

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

            // Flush already-downloaded entries from the queue periodically.
            // This makes things a little nicer if the application exists.
            auto now = Clock.currTime;
            if (now - lastWroteQueue > dur!"seconds"(15))
            {
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
        import std.array;
        if (urls.empty) return;
        auto u = urls.removeAny;
        if (u in urlMap) return;

        auto http = HTTP(u);
        writefln("downloading [%s, %s] %s", urlMap.length, urls.length, u);
        string contentType;
        Appender!(ubyte[]) buf;
        http.onReceive = (ubyte[] data)
        {
            buf ~= data;
            rateLimiter.limitRate(data.length);
            return data.length;
        };
        http.onReceiveHeader = (const(char[]) title, const(char[]) value)
        {
            if (title.toLower == "content-type")
            {
                contentType = value.idup.toLower;
            }
            else if (title.toLower == "content-length")
            {
                auto contentLength = value.to!ulong;
                if (contentLength > MAX_DOWNLOAD)
                {
                    infof("url %s: canceling download because the content length is %s, which is greater than the threshold of %s", u, contentLength, MAX_DOWNLOAD);
                    http.shutdown;
                }
                else
                {
                    buf.reserve(contentLength);
                }
            }
        };
        http.perform();
        contentType = contentType.toLower;
        if (contentType == "text/html" || contentType == "application/xhtml+xml")
        {
            writeln("content type is text/html; processing as html document");
            processHtml(assumeUnique(cast(char[])buf.data), contentType, u);
        }
        else
        {
            writeln("content type is ", contentType, "; just saving");
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
        import std.file : write;
        auto name = baseDir ~ "/" ~ sha1Of(b).toHexString().idup;
        write(name, b);
        urlMap.add(u, name, contentType);
    }

    void enqueue(URL u)
    {
        if (u.host != base.host)
        {
            writefln("url %s: doesn't have base host %s", u, base.host);
            return;
        }
        if (!u.path.startsWith(base.path))
        {
            writefln("url %s: doesn't have base path %s", u, base.path);
            return;
        }
        if (u in urlMap)
        {
            writefln("url %s: already saved to a file", u);
            return;
        }
        if (!urls.equalRange(u).empty)
        {
            writefln("url %s: already enqueued", u);
            return;
        }
        writefln("url %s: enqueueing", u);
        urls.insert(u);
        append(queueFile, u.toString ~ "\n");
    }
}
