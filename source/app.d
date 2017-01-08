module mirror.app;

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
    string[URL] urlToFile;
    URL base;
    string queueFile;
    string mapFile;
    string baseDir;

    this(string base)
    {
        this.urls = new RedBlackTree!URL;
        this.base = base.parseURL;
        baseDir = base.replace(":", "_").replace("/", "-");
        queueFile = "queue_" ~ baseDir;
        mapFile = "map_" ~ baseDir;
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
            foreach (i, line; mapFile.readText().splitLines())
            {
                if (line.length == 0) continue;
                auto parts = line.split(" -> ");
                if (parts.length != 2)
                {
                    writefln("%s line %s: malformed line: '%s'", mapFile, i + 1, line);
                }
                urlToFile[parts[1].parseURL] = parts[0];
            }
            writefln("read %s urls from already-downloaded map", urlToFile.length);
            before = urlToFile.length;
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
        writefln("downloaded %s files", urlToFile.length - before);
    }

    void step()
    {
        import std.array;
        if (urls.empty) return;
        auto u = urls.removeAny;
        if (u in urlToFile) return;

        auto http = HTTP(u);
        writefln("downloading [%s, %s] %s", urlToFile.length, urls.length, u);
        string contentType;
        Appender!(ubyte[]) buf;
        http.onReceive = (ubyte[] data) { buf ~= data; return data.length; };
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
            processHtml(assumeUnique(cast(char[])buf.data), u);
        }
        else
        {
            writeln("content type is ", contentType, "; just saving");
            processGeneralFile(buf.data, u);
        }
    }

    void processGeneralFile(const(ubyte[]) data, URL u)
    {
        save(data, u);
    }

    void processHtml(string html, URL url)
    {
        auto doc = new Document(html);
        // We're looking for <link rel=""> and <a href="">.
        // First pass, we skip images and stylesheets.
        // Also, assume it's UTF-8.
        foreach (a; doc.getElementsByTagName("a"))
        {
            auto href = a.getAttribute("href").idup;  // duplicate in case it's a slice to the original string
            auto u = url.resolve(href);
            writefln("mapping url %s in <a>", u);
            enqueue(u);
            a.setAttribute("href", relPath(u));
        }
        foreach (a; doc.getElementsByTagName("link"))
        {
            auto href = a.getAttribute("rel").idup;
            auto u = url.resolve(href);
            writefln("mapping url %s in <link>", u);
            enqueue(u);
            a.setAttribute("rel", relPath(u));
        }
        save(cast(immutable(ubyte)[])doc.toString, url);
    }

    void save(const ubyte[] b, URL u)
    {
        import std.digest.sha : sha1Of, toHexString;
        import std.file : write;
        auto name = baseDir ~ "/" ~ sha1Of(b).toHexString().idup;
        write(name, b);
        urlToFile[u] = name;
        mapFile.append(format("%s -> %s\n", name, u));
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
        if (u in urlToFile)
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
        append(queueFile, u.toString);
    }

    string relPath(URL u)
    {
        return u.path;
    }
}

void main(string[] args)
{
    foreach (arg; args[1..$])
    {
        auto d = new Downloader(arg);
        d.run;
    }
}
