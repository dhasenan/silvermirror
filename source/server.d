module mirror.server;

import mirror.common;
import mirror.config;

import std.array : array;

import url;
import vibe.d;

class Server
{
    Config cfg;
    string baseDir;

    Map urlToPath;

    this(Config cfg)
    {
        this.cfg = cfg;
        baseDir = getBaseDir(cfg);
        urlToPath = new Map(getMapFile(cfg));
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
        auto path = u.toPathAndQueryString;
        if (path == "/")
        {
            res.bodyWriter.write(`<html><head><title>Index of`);
            res.bodyWriter.write(cfg.baseURL.toString);
            res.bodyWriter.write(`</title></head><body>`);
            auto s = urlToPath.pages.values.array;
            // This fails, complainingthat std.algorithm.mutation.swap can't call non-@nogc function
            // std.exception.doesPointTo!(Page, Page, void).
            import std.algorithm;
            std.algorithm.sort(s);
            foreach (p; s)
            {
                res.bodyWriter.write(`<div><a href="/data`);
                res.bodyWriter.write(p.url.toPathAndQueryString);
                res.bodyWriter.write(`">`);
                res.bodyWriter.write(p.url.toPathAndQueryString);
                res.bodyWriter.write("</a></div>");
            }
            res.bodyWriter.write(`</body></html>`);
            return;
        }
        if (path.startsWith("/data"))
        {
            path = path[5..$];
            import std.stdio;
            writeln(path);
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
        res.bodyWriter.write(`<html><body><h1>Not Found</h1>The document was not found. If the mirror is still in progress, please be patient.</body></html>`);
    }

    void reloadMap()
    {
        urlToPath.read();
    }
}

void run(Config cfg)
{
    //if (!finalizeCommandLineOptions()) return;
    // this shouldn't hurt but won't usually be necessary
    lowerPrivileges();
    auto server = new Server(cfg);
    server.start();
    runEventLoop();
}
