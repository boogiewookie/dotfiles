#!/usr/bin/env python3
import psycopg2
from html import escape
import datetime
import configparser, os

def format_rfc1123(x):
    '''format datetime x, assumed to be in gmt, as an rfc 1123 timestamp'''
    w = ('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')[x.weekday()]
    y = x.year
    m = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')[x.month-1]
    d = x.day
    H = x.hour
    M = x.minute
    S = x.second
    return "{0:3s}, {1:02d} {2:3s} {3:04d} {4:02d}:{5:02d}:{6:02d} GMT".format(w,d,m,y,H,M,S)

html='''<!doctype html>
<!-- generated {0} by makebookmarks.py -->
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="expires" content="{1}">
'''.format(
        datetime.date.today().isoformat(),
        format_rfc1123(datetime.datetime.utcnow()+datetime.timedelta(days=1)))

html += '''
    <title>Bookmarks</title>
    <script src="https://ajax.googleapis.com/ajax/libs/jquery/1.11.1/jquery.min.js"></script>
    <script>
      $( document ).ready(function() {
          // register a callback for tags or regex boxes changing
          $( "#tags, #regex" ).on("change",function() {
            selector = ".item";
            $( selector ).hide();
            tags = $( "#tags" ).val().trim()
            if (tags.length > 0) {
              selector += "[tags~='" + tags.split(/\s+/).join("'][tags~='") + "']"
            }
            tagged = $( selector );

            re = $( "#regex" ).val();
            if (re == "") {
              tagged.show()
            }
            else
            {
              re = new RegExp(re,"i");
              tagged.each(function () {
                if ($( this ).text().search(re) != -1 || $( this).attr("title").search(re) != -1) {
                  $( this ).show()
                }
              });
            }
          });

          $("#tags").trigger("change")
      });
    </script>
    <style>
        .item {
            display: none;
        }
    </style>
  </head>
  <body>
    <div id="items">
      <input id="tags" placeholder="Tags" value="fave"/></td>
      <input id="regex" placeholder="Regex" /></td>
      <br>
'''

config = configparser.ConfigParser()
config.read([os.path.expanduser('~/.tagurit.ini'), os.path.expanduser('~/.database.ini')])
conn = psycopg2.connect(
        database='tagurit',
        host=config['tagurit']['host'],
        user=config['tagurit']['user'],
        password=config['tagurit']['password'])
cur = conn.cursor()
cur.execute("""SELECT title,url,notes,tags FROM items ORDER BY lower(title);""")

for row in cur:
    title,url,notes,tags = row
    title = escape(title)
    tooltip = escape(tags.strip())
    if notes != "":
       tooltip = escape(notes) + "\n" + tooltip
    html += '''<span tags="{3}" class="item"><a href="{1}" title="{2}" target="_blank">{0}</a>, </span>\n'''.format(title,url,tooltip,tags)

html += '''
    </div>
  </body>
</html>
'''

fh = open("/usr/local/www/data/bookmarks.html","w",encoding="utf_8")
fh.write(html)
fh.close()
