module mirror.common;

import mirror.config;

import std.experimental.logger;
import std.string : replace;
import std.stdio : File;
import std.file : readText;
import vibe.data.json;
import url;

string relPath(URL u)
{
    return "/data" ~ u.path;
}

string getBaseDir(Config config)
{
    if (config.path)
    {
        return config.path;
    }
    return config.baseURL.host;
}

string getMapFile(Config config)
{
    return config.path ~ "/map";
}

struct Page
{
    /// original URL of the file
    string _url;
    /// path to file
    string path;
    /// content type
    string contentType;

    int opCmp(ref const Page other) const
    {
        import std.algorithm.comparison : cmp;
        return cmp(_url, other._url);
    }

    URL url() const { return _url.parseURL; }
    void url(URL value) { _url = value.toString; }
}

class Map
{
    this(string filename)
    {
        this.filename = filename;
    }

    private string filename;
    Page[string] pages;

    Page* opIn_r(URL url)
    {
        return opIn_r(url.toPathAndQueryString);
    }

    Page* opIn_r(string path)
    {
        infof("Map.opIn: checking path %s", path);
        auto p = path in pages;
        if (p is null)
        {
            infof("%s not found", path);
        }
        else
        {
            infof("%s: returning page with url %s", path, p.url);
        }
        return p;
    }

    void add(Page p)
    {
        import std.stdio;
        // writefln("adding a page for url %s", p.url);
        pages[p.url.toPathAndQueryString] = p;
        // writefln("now have %s pages", pages.length);
        auto f = File(filename, "a");
        write(f, p);
        f.flush;
        f.close;
    }

    void add(URL url, string path, string contentType)
    {
        add(Page(url, path, contentType));
    }

    size_t length() { return pages.length; }
    
    void read()
    {
        import std.stdio, std.file;
        writefln("reading %s", filename);
        if (!(filename.exists && filename.isFile))
        {
            // nothing to read
            return;
        }
        auto text = filename.readText();
        // Whenever we write a value, we write a comma before.
        // Start with a placeholder.
        auto range = `{"values":[null` ~ text ~ `]}`;
        auto js = range.parseJson;
        auto vals = js["values"];
        Page[string] p;
        foreach (size_t i, Json v; vals)
        {
            // skip the placeholder
            if (v.type == Json.Type.null_) continue;
            auto u = v["url"].get!string.parseURL;
            p[u.toPathAndQueryString] = Page(u, v["path"].get!string, v["contentType"].get!string);
        }
        pages = p;
    }

    void write()
    {
        auto f = File(filename, "w");
        foreach (k, p; pages)
        {
            write(f, p);
        }
        f.flush;
        f.close;
    }

    private void write(ref File f, Page p)
    {
        f.write(",\n");
        auto js = Json.emptyObject;
        js["url"] = p.url.toString;
        js["path"] = p.path;
        js["contentType"] = p.contentType;
        f.write(js.toString);
    }
}
