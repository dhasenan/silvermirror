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
        return url.path in pages;
    }

    Page* opIn_r(string path)
    {
        return path in pages;
    }

    void add(Page p)
    {
        import std.stdio;
        // writefln("adding a page for url %s", p.url);
        pages[p.url.path] = p;
        // writefln("now have %s pages", pages.length);
        auto f = File(filename, "a");
        write(f, p, pages.length <= 1);
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
        import std.stdio;
        writefln("reading %s", filename);
        auto text = filename.readText();
        auto range = `{"values":[` ~ text ~ `]}`;
        auto js = range.parseJson;
        auto vals = js["values"];
        Page[string] p;
        foreach (size_t i, Json v; vals)
        {
            auto u = v["url"].get!string.parseURL;
            p[u.path] = Page(u, v["path"].get!string, v["contentType"].get!string);
        }
        pages = p;
    }

    void write()
    {
        auto f = File(filename, "w");
        bool first = true;
        foreach (k, p; pages)
        {
            write(f, p, first);
            first = false;
        }
        f.flush;
        f.close;
    }

    private void write(ref File f, Page p, bool first)
    {
        import std.stdio : writefln;
        if (!first)
        {
            // writefln("page %s is not the first page; inserting separator", p.url);
            f.write(",\n");
        }
        auto js = Json.emptyObject;
        js["url"] = p.url.toString;
        js["path"] = p.path;
        js["contentType"] = p.contentType;
        f.write(js.toString);
    }
}
