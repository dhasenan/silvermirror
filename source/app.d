module mirror.app;

import std.getopt;
import std.stdio;
import mirror.downloader;
import mirror.server;
import mirror.html_template;

void main(string[] args)
{
    string serve;
    string[] download;
    string templ;
    bool helpWanted;
    auto info = getopt(
            args,
            "serve|s", &serve,
            "download|d", &download,
            "template|t", &templ,
            "help|h", &helpWanted
          );
    if (info.helpWanted || helpWanted)
    {
        defaultGetoptPrinter("mirror websites", info.options);
        return;
    }
    if (serve)
    {
        mirror.server.run(serve);
    }
    else if (download)
    {
        Template t;
        if (templ)
        {
            import std.file : readText;
            t = Template.parse(templ.readText);
        }
        foreach (arg; download)
        {
            new Downloader(arg, t).run;
        }
    }
}

void showHelp(string exe)
{
    writefln("Usage:");
    writefln("\t%s url [url...]", exe);
    writefln("\t%s --serve url", exe);
}
