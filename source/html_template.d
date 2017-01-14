module mirror.html_template;

import arsd.dom;
import std.array;
import std.experimental.logger : debugf;
import std.format;
import std.string;
import std.variant;
import url;

/**
    A template inspired by Ruby's string interpolation syntax. However, instead of referring to
    variables, we instead use CSS selectors.

    We have one special selector: url. This refers to the original URL of the page.

    Prepend the selector with a minus sign to include the inner HTML, a dollar sign to include the
    inner text; a plus sign or nothing to include the whole thing.

    So, given the template:
    ---
    <html>
      <head>
        <title>#{$title} (#{url})</title>
        <link rel="stylesheet" href="/static/style.css" />
      </head>
      <body>
        <h1>#{$div.header}</h1>
        <div id="main">
          #{div.content}
        </div>
      </body>
    </html>
    ---

    And the input, downloaded from https://bonobos4sale.com/index.htm :
    ---
    <html>
      <head>
        <title>Bonobos n' More!</title>
      </head>
      <body>
        <div class="header">The <em>best</em> in the <strong>industry</strong>!!</div>
        <div class="filler">Llorem ipsum</div>
        <div class="content" id="first">Bonobos for cheap!</div>
        <div class="filler">Llorem ipsum</div>
        <div class="content" id="second">Bonobos for <em>free</em>!</div>
      </body>
    </html>
    ---

    You get:
    ---
    <html>
      <head>
        <title>Bonobos n' More! (https://bonobos4sale.com/index.htm)</title>
        <link rel="stylesheet" href="/static/style.css" />
      </head>
      <body>
        <h1>The best in the industry!!</h1>
        <div id="main">
          <div class="content" id="first">Bonobos for cheap!</div>
          <div class="content" id="second">Bonobos for <em>free</em>!</div>
        </div>
      </body>
    </html>
    ---

    Pretty printing not guaranteed.
*/
struct Template
{
    static Template parse(string value)
    {
        Elem[] elems;
        auto orig = value;
        while (value.length > 0)
        {
            auto idx = value.indexOf("#{");
            if (idx < 0)
            {
                elems ~= Elem(Literal(value));
                value = null;
                break;
            }
            if (idx > 0)
            {
                elems ~= Elem(Literal(value[0..idx]));
            }
            value = value[idx + 2..$];
            auto end = value.indexOf("}");
            if (end < 0)
            {
                throw new Exception("unterminated #{} at %s".format(orig.length - value.length));
            }
            if (end == 0)
            {
                throw new Exception("empty #{} at char %s".format(orig.length - value.length));
            }
            auto v = value[0..end];
            debugf("have content %s; start=%s; end=%s", v, idx, end);
            value = value[end + 1 .. $];
            Selector selector;
            if (v[0] == '-')
            {
                selector.value = v[1..$];
                selector.type = Selector.Type.Inner;
            }
            else if (v[0] == '$')
            {
                selector.value = v[1..$];
                selector.type = Selector.Type.Text;
            }
            else if (v[0] == '+')
            {
                selector.value = v[1..$];
                selector.type = Selector.Type.Self;
            }
            else
            {
                selector.value = v;
                selector.type = Selector.Type.Self;
            }
            elems ~= Elem(selector);
        }
        return Template(elems);
    }

    Elem[] elems;

    string evaluate(Document doc, URL u)
    {
        if (elems.length == 0)
        {
            return doc.toString;
        }
        Appender!string a;
        foreach (elem; elems)
        {
            if (auto p = elem.peek!Literal)
            {
                a ~= p.value;
            }
            else if (auto p = elem.peek!Selector)
            {
                if (p.value == "url")
                {
                    a ~= u.toHumanReadableString;
                }
                else
                {
                    auto matches = doc.getElementsBySelector(p.value);
                    foreach (match; matches)
                    {
                        a ~= p.from(match);
                    }
                }
            }
        }
        return a.data;
    }
}

struct Literal
{
    string value;
}

struct Selector
{
    enum Type
    {
        Inner,
        Self,
        Text
    }

    string value;
    Type type;

    string from(Element e)
    {
        final switch (type)
        {
            case Type.Inner:
                return e.innerHTML;
            case Type.Self:
                return e.toString;
            case Type.Text:
                return e.innerText;
        }
    }
}

alias Elem = Algebraic!(Literal, Selector);


unittest
{
    import std.array : array;
    import std.algorithm : filter;
    import std.conv : to;

    auto original = `<html>
    <head>
        <title>Original Title</title>
    </head>
    <body>
        <div id="main">
            <span class="foo"><em>Some</em> things are better left unsaid</span>
        </div>
    </body>
</html>`;
    auto templ = Template.parse(`#{title}
#{-#main}
#{$span.foo}
#{url}`);
    auto doc = new Document(original);
    auto eval = templ.evaluate(doc, "http://example.org".parseURL);
    auto expected = `<title>Original Title</title>
            <span class="foo"><em>Some</em> things are better left unsaid</span>
Some things are better left unsaid
http://example.org/`;
    auto reallyExpected = expected.filter!(x => x != ' ' && x != '\n').array.to!string;
    auto actual = eval.filter!(x => x != ' ' && x != '\n').array.to!string;
    assert(
        actual == reallyExpected,
        "Expected:\n[[[" ~ reallyExpected ~ "]]]\nActual:\n[[[" ~ actual ~ "]]]");
}