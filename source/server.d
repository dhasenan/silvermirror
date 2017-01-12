module mirror.server;

import mirror.common;

import url;
import vibe.d;

class Server
{
    string base;
    string baseDir;

    Map urlToPath;

    this(string base)
    {
        this.base = base;
        baseDir = getBaseDir(base);
        urlToPath = new Map(getMapFile(base));
    }

    void start()
    {
        reloadMap();
        setTimer(5.seconds, &reloadMap);

        auto settings = new HTTPServerSettings;
        settings.port = 7761;
        //settings.bindAddresses = ["0.0.0.0"];
        listenHTTP(settings, &handleRequest);
    }

    void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        // TODO content-type
        auto u = req.requestURL.parseURL;
        auto path = u.path;
        if (path == "/")
        {
            res.bodyWriter.write(`<html><head><title>Index of`);
            res.bodyWriter.write(base);
            res.bodyWriter.write(`</title></head><body>`);
            auto s = urlToPath.pages.values.array;
            // This fails, complainingthat std.algorithm.mutation.swap can't call non-@nogc function
            // std.exception.doesPointTo!(Page, Page, void).
            import std.algorithm;
            std.algorithm.sort(s);
            foreach (p; s)
            {
                res.bodyWriter.write(`<div><a href="/data`);
                res.bodyWriter.write(p.url.path);
                res.bodyWriter.write(`">`);
                res.bodyWriter.write(p.url.path);
                res.bodyWriter.write("</a></div>");
            }
            res.bodyWriter.write(`</body></html>`);
            return;
        }
        if (path.startsWith("/data"))
        {
            path = path[5..$];
            if (auto p = path in urlToPath)
            {
                auto page = *p;
                res.contentType = page.contentType;
                res.bodyWriter.write(readFile(page.path));
                return;
            }
        }
        res.statusCode = 404;
        res.contentType = "text/html; charset=UTF-8";
        res.writeBody(`<html><body><h1>Not Found</h1>The document was not found. If the mirror is still in progress, please be patient.</body></html>`);
    }

    void reloadMap()
    {
        urlToPath.read();
    }
}

void run(string urlString)
{
    //if (!finalizeCommandLineOptions()) return;
    // this shouldn't hurt but won't usually be necessary
    lowerPrivileges();
    auto server = new Server(urlString);
    server.start();
    runEventLoop();
}
