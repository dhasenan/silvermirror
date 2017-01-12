module mirror.config;

import mirror.html_template;

import url;

import vibe.data.json;

class Config
{
    /// the URL to download
    URL baseURL;

    /// skip files larger than this
    size_t fileSizeCutoff = 32 * 1024 * 1024;

    /// quit after downloading this many files (handy for testing)
    size_t maxFiles = size_t.max;

    /// bytes/second target
    size_t rateLimit = size_t.max;   

    /// the template to use on downloaded HTML documents
    Template htmlTemplate;

    /// the user agent string to report
    string userAgent = "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:47.0) " ~ 
        "Gecko/20100101 Firefox/47.0";

    this(Json json)
    {
        if ("url" in json)
        {
            baseURL = json["url"].get!string().parseURL;
        }
        if ("fileSizeCutoff" in json)
        {
            fileSizeCutoff = json["fileSizeCutoff"].get!size_t;
        }
        if ("maxFiles" in json)
        {
            maxFiles = json["maxFiles"].get!size_t;
        }
        if ("rateLimit" in json)
        {
            rateLimit = json["rateLimit"].get!size_t;
        }
        if ("userAgent" in json)
        {
            userAgent = json["userAgent"].get!string;
        }
        if ("template" in json)
        {
            import std.file : readText;
            auto templateFile = json["template"].get!string;
            htmlTemplate = Template.parse(templateFile.readText);
        }
    }

    this(string path)
    {
        this(path.readText.parseJsonString);
    }
}
