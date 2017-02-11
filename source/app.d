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
    bool serve;
    string configFile;
    bool helpWanted;
    bool verbose;
    ushort port = 7761;
    auto info = getopt(
            args,
            "serve|s", &serve,
            "config|c", &configFile,
            "port|p", &port,
            "help|h", &helpWanted,
            "verbose|v", &verbose
          );
    if (info.helpWanted || helpWanted || !configFile)
    {
        defaultGetoptPrinter("mirror websites", info.options);
        return;
    }
    if (verbose)
    {
        globalLogLevel = LogLevel.info;
    }
    else
    {
        globalLogLevel = LogLevel.warning;
    }
    auto cfg = new Config(configFile);
    infof("loaded config");
    if (serve)
    {
        mirror.server.run(cfg, port);
    }
    else
    {
        infof("running downloader");
        new Downloader(cfg).run;
    }
}
