#!/usr/bin/env bash
# Upgrade omeka.library.appstate.edu to Omeka Classic 3.2.2 and the latest plugins.
# Run each phase as root, in order, and read its output before the next one:
#
#   sudo bash omeka-upgrade.sh check      # 1.   read-only pre-flight
#   sudo bash omeka-upgrade.sh prepare    # 2-4. back up DB, stage 3.2.2, update plugins (live site untouched)
#   sudo bash omeka-upgrade.sh swap       # 5.   put 3.2.2 live, then do the browser steps it prints
#   sudo bash omeka-upgrade.sh rollback   #      only if needed
#   sudo bash omeka-upgrade.sh cleanup    #      after a week or so
#
# Settings can also come from the environment, e.g.
#   sudo OMEKA=/var/www/omeka bash omeka-upgrade.sh check
# For a later Omeka release, change VERSION and ZIP_SHA256 (sha256sum of the release zip).
# Needs bash, php (CLI), curl, unzip, mysqldump/mysql. Tested on Ubuntu 24.04 with CLI PHP 7.2 and 8.4.

[ -n "$BASH_VERSION" ] || { echo "Run this with bash: sudo bash $0 check"; exit 1; }

OMEKA=${OMEKA:-/var/www/html}       # the site's DocumentRoot (the folder that contains db.ini)
SITE_URL=${SITE_URL:-http://152.10.8.17/}
VERSION=3.2.2
ZIP_SHA256=5b93846f15614ea32b105f748286c4e53b74c295130cc47f551330cb323d3e68
PLUGIN_INDEX=${PLUGIN_INDEX:-https://omeka.org/add-ons/json/classic_plugin.json}

PARENT=$(dirname "$OMEKA")
NEW="$PARENT/omeka-$VERSION"                  # staging copy
READY="$NEW.ready"                            # written only when 'prepare' finishes
OLD="$OMEKA.pre-$VERSION"                     # old code, kept for rollback
DUMP="/root/omeka-db-pre-$VERSION.sql.gz"     # database backup


die()     { echo "STOP: $*" >&2; exit 1; }
heading() { printf '\n== %s\n' "$*"; }

version_of() { sed -n "s/.*OMEKA_VERSION', '\([^']*\)'.*/\1/p" "$1/bootstrap.php"; }

load_db_creds() {
  eval "$(php -r '
    $c = parse_ini_file($argv[1], true)["database"];
    foreach (["host", "username", "password", "dbname", "port", "prefix"] as $k)
        echo "DB_$k=", escapeshellarg($c[$k] ?? ""), "\n";
  ' "$OMEKA/db.ini")"
  [ -n "$DB_dbname" ] || die "couldn't read the database settings in $OMEKA/db.ini"
}

db_sql() {
  MYSQL_PWD="$DB_password" mysql -N -h "$DB_host" ${DB_port:+-P "$DB_port"} \
      -u "$DB_username" "$DB_dbname" -e "$1"
}

reload_web() {   # graceful reload so PHP's opcache drops the code it had cached
  local units u
  units=$(systemctl list-units --type=service --state=running --plain --no-legend 2>/dev/null |
          awk '{print $1}' | grep -E '^(httpd|apache2|.*php.*fpm.*)\.service$')
  if [ -n "$units" ]; then
    for u in $units; do systemctl reload "$u" && echo "reloaded $u"; done
  elif command -v apachectl >/dev/null; then
    apachectl graceful && echo "reloaded Apache"
  else
    echo "(couldn't find Apache/PHP-FPM to reload; reload them yourself now)"
  fi
}


# -- 1. Pre-flight (read-only)
check() {
  local problems=0 c d oldv

  heading "Tools"
  for c in php curl unzip mysqldump sha256sum; do
    command -v "$c" >/dev/null || { echo "missing: $c"; problems=1; }
  done
  php -v | head -1
  php -r 'exit(version_compare(PHP_VERSION, "7.1", ">=") ? 0 : 1);' ||
    { echo "PHP is older than 7.1, which 3.2.2 requires"; problems=1; }
  php -r 'exit(function_exists("json_decode") ? 0 : 1);' ||
    { echo "PHP's json extension is missing (RHEL 8: dnf install php-json)"; problems=1; }
  command -v getenforce >/dev/null && echo "SELinux: $(getenforce)"

  heading "Current version and plugins"
  oldv=$(version_of "$OMEKA")
  echo "Omeka $oldv  ->  $VERSION"
  grep -H '^version' "$OMEKA"/plugins/*/plugin.ini

  heading "Theme/plugin folder names 3.2.2 will reject (rename or remove these)"
  for d in "$OMEKA"/themes/*/ "$OMEKA"/plugins/*/; do
    [[ $(basename "$d") =~ ^[A-Za-z0-9_-]+$ ]] || { echo "bad name: $d"; problems=1; }
  done

  heading "Core files that differ from stock $oldv"
  echo "(db.ini, .htaccess, config.ini, errors.log and robots.txt are carried over;"
  echo " anything else listed here is a local edit you'll need to re-apply)"
  curl -fsSL --retry 3 "https://github.com/omeka/Omeka/releases/download/v$oldv/omeka-$oldv.zip" -o "/tmp/omeka-$oldv.zip" &&
    unzip -qo "/tmp/omeka-$oldv.zip" -d /tmp && rm -rf "/tmp/omeka-$oldv/files" &&
    diff -rq "/tmp/omeka-$oldv" "$OMEKA" | grep -v "^Only in $OMEKA"

  echo
  if [ "$problems" = 0 ]; then echo "Pre-flight OK."; else echo "Fix the items above before 'prepare'."; fi
  return $problems
}


# -- 2-4. Back up, stage, update plugins (live site untouched)
prepare() {
  local f d rel have have_needs why latest url tmp new_ini needs last colstats= broken=

  check || die "pre-flight found problems"
  [ -e "$OLD" ] && die "$OLD already exists; has the swap already run?"
  rm -f "$READY"

  heading "2. Database backup -> $DUMP"
  load_db_creds
  # MySQL 8's mysqldump wants this off when the server is MariaDB; MariaDB's doesn't have it
  mysqldump --help 2>/dev/null | grep -q -- '--column-statistics' && colstats=--column-statistics=0
  ( umask 077                                   # the dump holds user emails and password hashes
    MYSQL_PWD="$DB_password" mysqldump --single-transaction --no-tablespaces $colstats \
        -h "$DB_host" ${DB_port:+-P "$DB_port"} -u "$DB_username" "$DB_dbname" \
      | gzip > "$DUMP" )
  last=$(zcat "$DUMP" | tail -1)
  [[ $last == *"Dump completed"* ]] || die "database backup is incomplete: $DUMP"
  echo "$last"

  heading "3. Stage $VERSION in $NEW"
  cd "$PARENT" || die "can't cd to $PARENT"
  curl -fLO --retry 3 "https://github.com/omeka/Omeka/releases/download/v$VERSION/omeka-$VERSION.zip" || die "download failed"
  echo "$ZIP_SHA256  omeka-$VERSION.zip" | sha256sum -c || die "checksum mismatch"
  rm -rf "$NEW" && unzip -q "omeka-$VERSION.zip" || die "unzip failed"

  # Your config
  cp -a "$OMEKA/db.ini" "$OMEKA/.htaccess" "$NEW/"
  cp -a "$OMEKA/application/config/config.ini" "$NEW/application/config/"

  # Anything else in the docroot the release doesn't ship (robots.txt, verification files, ...)
  comm -23 <(ls -A "$OMEKA" | sort) <(ls -A "$NEW" | sort) |
    while IFS= read -r f; do
      echo "carry over: $f"
      cp -a "$OMEKA/$f" "$NEW/"
    done

  # Your themes and plugins (bundled ones come from the new release)
  for d in "$OMEKA"/themes/*/ "$OMEKA"/plugins/*/; do
    rel=${d#"$OMEKA"/}; rel=${rel%/}
    [ -e "$NEW/$rel" ] || cp -a "$OMEKA/$rel" "$NEW/$rel"
  done

  heading "4. Update plugins in the staging copy (latest releases on omeka.org)"
  curl -fsSL --retry 3 "$PLUGIN_INDEX" -o /tmp/omeka-plugins.json || die "can't download the plugin directory ($PLUGIN_INDEX)"
  ini()   { php -r 'echo @parse_ini_file($argv[1])[$argv[2]] ?? "0";' "$1" "$2"; }
  newer() { php -r 'exit(version_compare($argv[1], $argv[2], ">") ? 0 : 1);' "$1" "$2"; }

  cd "$NEW/plugins" || die "can't cd to $NEW/plugins"
  for d in */; do
    d=${d%/}
    have=$(ini "$d/plugin.ini" version)
    have_needs=$(ini "$d/plugin.ini" omeka_minimum_version)
    read -r latest url < <(php -r '
      foreach ((array) json_decode(@file_get_contents($argv[1]), true) as $key => $p)
        if (($p["dirname"] ?? $key) === $argv[2]) {
          $v = $p["latest_version"];
          echo $v, " ", $p["versions"][$v]["download_url"] ?? "";
        }
    ' /tmp/omeka-plugins.json "$d")

    # A copy that needs a newer Omeka won't load. The 3.2.2 zip itself bundles
    # Simple Pages 3.4, which needs 3.3, so that one gets swapped for 3.3.1.
    why=""
    newer "$have_needs" "$VERSION" && why="  ($have needs Omeka $have_needs)"

    if [ -z "$url" ]; then
      if [ -n "$why" ]; then broken+=" $d"; echo "BROKEN  $d$why, and it isn't in the omeka.org directory"
      else echo "manual  $d $have  (not in omeka.org directory; left as is)"; fi
      continue
    fi
    if [ -z "$why" ] && ! newer "$latest" "$have"; then echo "ok      $d $have"; continue; fi

    tmp=$(mktemp -d -p "$PARENT")    # same filesystem, so ownership/SELinux labels match
    curl -fsSL --retry 3 "$url" -o "$tmp/p.zip" && unzip -q "$tmp/p.zip" -d "$tmp"
    new_ini=$(find "$tmp" -mindepth 2 -maxdepth 3 -name plugin.ini | head -1)
    needs=$([ -n "$new_ini" ] && ini "$new_ini" omeka_minimum_version)

    if [ -z "$new_ini" ]; then
      echo "FAILED  $d  (download: $url)"; [ -n "$why" ] && broken+=" $d"
    elif newer "$needs" "$VERSION"; then
      echo "skip    $d $latest needs Omeka $needs; keeping $have"; [ -n "$why" ] && broken+=" $d"
    else
      rm -rf "$d" && mv "$(dirname "$new_ini")" "$d" && echo "update  $d $have -> $latest$why"
    fi
    rm -rf "$tmp"
  done
  [ -z "$broken" ] || echo "WARNING: these won't load on Omeka $VERSION:$broken"

  touch "$READY"
  echo
  echo "Staged in $NEW. The live site hasn't changed."
  echo "Next: sudo bash $0 swap   (then the browser steps it prints)"
}


# -- 5. Swap the staged copy in (public site is down until the DB upgrade)
swap() {
  [ -f "$READY" ] || die "'prepare' hasn't finished successfully; run it (again) first"
  [ -e "$OLD" ] && die "$OLD already exists; has the swap already run?"
  [ -f "$DUMP" ] || die "no database backup at $DUMP; run 'prepare' first"

  # Same owner and (on RHEL) same SELinux label as the live code
  chown -R --reference="$OMEKA/index.php" "$NEW"
  if command -v selinuxenabled >/dev/null && selinuxenabled; then
    chcon -R --reference="$OMEKA/index.php" "$NEW" || die "couldn't set SELinux labels on $NEW"
  fi
  # Keep the live logs folder as is (it has to stay writable by the web server)
  rm -rf "$NEW/application/logs" && cp -a "$OMEKA/application/logs" "$NEW/application/"

  # files/ never moves, so this also works if it's a symlink or a mount
  mkdir "$OLD" &&
    find "$OMEKA" -mindepth 1 -maxdepth 1 ! -name files -exec mv -t "$OLD" {} + &&
    find "$NEW"   -mindepth 1 -maxdepth 1 ! -name files -exec mv -t "$OMEKA" {} + ||
    die "swap failed part-way; old code is in $OLD, new code in $NEW"
  rm -f "$READY"
  reload_web

  cat <<EOF

$OMEKA is now Omeka $(version_of "$OMEKA"). Do these in the browser right away:
  6. $SITE_URL/admin  ->  "Upgrade Database"
  7. Log in -> Plugins -> click "Upgrade" on every plugin that shows it
  8. Settings -> General -> Server URL must read $SITE_URL
  9. Spot-check: home page, an exhibit, an audio item, a PDF item,
     $SITE_URL/oai-pmh-repository/request?verb=Identify
If something's wrong: sudo bash $0 rollback
EOF
}


# -- Rollback: old code + pre-upgrade database
rollback() {
  local want fixed
  [ -d "$OLD" ] && [ -n "$(ls -A "$OLD")" ] || die "no previous version in $OLD"
  [ -f "$DUMP" ] || die "no database backup at $DUMP"
  [ -e "$OMEKA.failed" ] && die "$OMEKA.failed already exists; move it out of the way first"

  mkdir "$OMEKA.failed" &&
    find "$OMEKA" -mindepth 1 -maxdepth 1 ! -name files -exec mv -t "$OMEKA.failed" {} + &&
    find "$OLD"   -mindepth 1 -maxdepth 1 -exec mv -t "$OMEKA" {} + ||
    die "rollback failed part-way; see $OMEKA.failed and $OLD"
  rmdir "$OLD"
  reload_web          # before the restore, so no request runs cached 3.2.2 code against the old DB

  load_db_creds
  zcat "$DUMP" | MYSQL_PWD="$DB_password" mysql -h "$DB_host" ${DB_port:+-P "$DB_port"} \
      -u "$DB_username" "$DB_dbname" || die "database restore failed"
  reload_web

  # A request that ran cached 3.2.2 code against the restored database stamps it
  # "3.2.2" (Omeka does that when it finds no migrations to run). A retry of the
  # upgrade would then skip its migrations, so put the real version back.
  sleep 3
  want=$(version_of "$OMEKA")
  fixed=$(db_sql "UPDATE \`${DB_prefix}options\` SET value='$want'
                  WHERE name='omeka_version' AND value<>'$want'; SELECT ROW_COUNT();")
  [ "$fixed" = 0 ] || echo "(reset the database's stored version back to $want)"

  echo "Rolled back to Omeka $want and the pre-upgrade database. $VERSION is in $OMEKA.failed."
}


# -- Cleanup (after a week or so)
cleanup() {
  local answer
  read -rp "Delete the old code in $OLD? You can't roll back after this. [y/N] " answer
  [[ $answer == [yY]* ]] || die "nothing deleted"
  rm -rf "$OLD" "$NEW" "$READY" "$OMEKA.failed" "$PARENT/omeka-$VERSION.zip"
  echo "Removed the old code, staging copy and zip. The database backup is still at $DUMP."
}


[ "$(id -u)" = 0 ] || die "run as root: sudo bash $0 ${1:-check}"
[ -f "$OMEKA/db.ini" ] && [ -f "$OMEKA/bootstrap.php" ] ||
  die "OMEKA=$OMEKA doesn't look like the Omeka folder; edit the OMEKA= line at the top"

case "$1" in
  check|prepare|swap|rollback|cleanup) "$1" ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
