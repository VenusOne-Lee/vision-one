"""Prints a one-item Sparkle appcast. Called by make-appcast.sh."""
import email.utils
import html
import os
import re

version = os.environ["VERSION"]
build = os.environ["BUILD_NUMBER"]
url = os.environ["DOWNLOAD_URL"]
signature = os.environ["SIGNATURE"]
notes_path = os.environ.get("NOTES", "")

sig = re.search(r'sparkle:edSignature="([^"]+)"', signature)
length = re.search(r'length="(\d+)"', signature)
if not sig or not length:
    raise SystemExit(f"sign_update gave no signature: {signature!r}")


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    return re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)


def notes_html(markdown):
    """Just enough Markdown for release notes: headings, bullets, paragraphs."""
    out, in_list = [], False
    for line in markdown.splitlines():
        line = line.rstrip()
        bullet = re.match(r"^\s*[-*]\s+(.*)", line)
        if bullet and not in_list:
            out.append("<ul>")
            in_list = True
        if not bullet and in_list:
            out.append("</ul>")
            in_list = False
        if bullet:
            out.append(f"<li>{inline(bullet.group(1))}</li>")
        elif heading := re.match(r"^#{1,6}\s+(.*)", line):
            out.append(f"<h3>{inline(heading.group(1))}</h3>")
        elif line.strip():
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


notes = ""
if notes_path and os.path.exists(notes_path):
    with open(notes_path, encoding="utf-8") as f:
        notes = notes_html(f.read())
if not notes:
    notes = f"<p>Vision One {html.escape(version)}.</p>"
notes = notes.replace("]]>", "]]&gt;")

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Vision One</title>
    <link>https://github.com/VenusOne-Lee/vision-one</link>
    <language>en</language>
    <item>
      <title>Vision One {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure url="{html.escape(url)}" length="{length.group(1)}" type="application/octet-stream" sparkle:edSignature="{sig.group(1)}"/>
    </item>
  </channel>
</rss>""")
