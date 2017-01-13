module mirror.app;

import std.experimental.logger;
import std.getopt;
import std.stdio;

import mirror.config;
import mirror.downloader;
import mirror.server;
import mirror.html_template;

void main(string[] args)
{
    globalLogLevel = LogLevel.warning;
    bool serve;
    string configFile;
    bool helpWanted;
    auto info = getopt(
            args,
            "serve|s", &serve,
            "config|c", &configFile,
            "help|h", &helpWanted
          );
    if (info.helpWanted || helpWanted || !configFile)
    {
        defaultGetoptPrinter("mirror websites", info.options);
        return;
    }
    auto cfg = new Config(configFile);
    if (serve)
    {
        mirror.server.run(cfg);
    }
    else
    {
        new Downloader(cfg).run;
    }
}
