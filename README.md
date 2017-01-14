# Silvermirror: clone websites

Silvermirror lets you clone a foreign website.

_Well, what's the big deal?_ I hear you ask. _I can do that with wget._

Sure, but there are a couple points of awkwardness with wget:

 * Resumability. If wget fails halfway through the download, how do you restart?
 * Memory usage. When downloading a large site (several gigabytes), wget tends to consume large
   amounts of RAM.
 * URL mapping. wget attempts to produce the closest approximation of the website that a filesystem
   can handle. This results in some differences (eg if '/this' and '/this/' are different) and some
	 outright incorrect behavior (if '/this/' and '/this/index.html' are different).
 * Encoding and content type. wget doesn't preserve any encoding or content type information, so you
   end up with browser detection no matter what you do. This is often bad.
 * Progress. wget's output format is verbose, but it doesn't contain any useful information. While
   it's generally impossible to tell how much of a site is left to mirror, it would be useful to
	 print how many pages have been downloaded and how many are enqueued.

This makes it difficult, if not impossible, to use wget to produce a read-only mirror for a failing
website. You will break some external links even if you manage to acquire the domain name, and the
results may be unreadable.

Aside from that, it would be great if identical files were only stored once locally. It would also
be awesome if we could apply some reasonable mutations to the HTML when acquiring it.


## Using Silvermirror

Instead of providing a thousand and one command line options, Mirror uses a configuration file,
which is a simple JSON format:

```JavaScript
{
	"url": "http://example.org",
  "rateLimit": 100,         // kilobytes/second
  "fileSizeCutoff": 32768,  // kilobytes
	"maxFiles": 20,           // stop after downloading this many
	"userAgent": "MSIE",      // in case the site is a butt about user agents
	"template": "myTemplate", // template to apply to downloaded HTML
	"path": "download/to",    // where to put downloaded files

	// URL prefixes to ignore
	"exclude": [
		"http://example.org/wp-admin"
	]
}
```

Then you can kick off the download:

```
mirror --config config_file.json
```

At any point during and after the download, you can have Mirror serve it:

```
mirror --serve --config config_file.json
```


## Using Silvermirror to replace a site

By default, Silvermirror doesn't provide SSL and remaps URLs slightly. You are intended to use a
reverse proxy such as Nginx or Apache, mapping `/path?query` to `localhost:7761/data/path?query`.


## Templates

Templates are optional. If you don't specify a template, you get the entire document.

Templates only apply to documents with a Content-Type of `text/html` or `application/xhtml+xml`.

The template syntax is inspired by Ruby's string interpolation. However, in place of variables, you
have CSS selectors. We add one special selector, `url`, that maps to the original URL of the page.

Normal selectors have an optional prefix: `$` indicates to take the inner text, `-` indicates to
take the inner HTML (the element's children, excluding the element tag itself), `+` and unmarked
takes the outer HTML (the element and its children).

* `$`: inner text
* `+`: outer HTML (the element and its children) (default)
* `-`: inner HTML (the element's children only)

Some examples of the syntax:

* `#{$title}`: the title of the page
* `#{-span.b2}`: the HTML contents of each `<span class="b2">`
* `#{+.article h1}`: every `<h1>` element inside an element with the `article` class
* `#{.article h1}`: same as the previous

For instance, let's say I'm mirroring a blog with this sort of page:

```HTML
<html>
	<head>
		<title>Pondering Ornithiscians: Ian Malcolm's Mind</title>
	</head>
	<body>
		<h1>Ian Malcolm's Mind</h1>
		<h2>Abandan All Hope, Ye Who Enter Here!</h2>
		<div id="mainContent">
			<h2>Pondering Ornithiscians</h2>
			<div class="article">
				Ornithiscians would eat us for lunch.

				Even the small ones would snack on us. In packs.

				Have a nice day.
			</div>
		</div>
	</body>
</html>
```

I want to pare this down a bit. I'm going to extract out the page title, the article title, and the
article content:

```HTML
<html>
	<head>
		<title>#{$title} (mirror)</title>
	</head>
	<body>
		<h1>#{-div#mainContent h2}</h1>
		#{div.article}
	</body>
</html>
```

Which produces:

```HTML
<html>
	<head>
		<title>Pondering Ornithiscians: Ian Malcolm's Mind (mirror)</title>
	</head>
	<body>
		<h1>Pondering Ornithiscians</h1>
				Ornithiscians would eat us for lunch.

				Even the small ones would snack on us. In packs.

				Have a nice day.
	</body>
</html>
```

Done!
