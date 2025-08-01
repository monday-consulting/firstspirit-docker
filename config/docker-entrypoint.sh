#!/bin/sh

set -e

# Copy install files on first startup
if [ ! -f "$FS_BASEDIR/INSTALL_FILES_COPIED" ];
  then
    cp -r --update=none "$FS_INSTALLDIR/." "$FS_BASEDIR"
    touch "$FS_BASEDIR/INSTALL_FILES_COPIED"
fi

# If version in install dir is different from version in base dir then copy server files
cmp -s "$FS_INSTALLDIR/.version" "/$FS_BASEDIR/.version" || \
echo "Version files are different. Updating firstspirit server..." && \
cp -r "$FS_INSTALLDIR/server/." "$FS_BASEDIR/server" && \
cp -r "$FS_INSTALLDIR/bin/." "$FS_BASEDIR/bin" && \
cp "$FS_INSTALLDIR/.fs-rt.ver" "$FS_BASEDIR/.fs-rt.ver" && \
cp -r --update=none "$FS_INSTALLDIR/conf/." "$FS_BASEDIR/conf" && \
cp "$FS_INSTALLDIR/.version" "$FS_BASEDIR/.version"

# Adjust version in banner
sed -i 's/cms\.ftp\.version/'"$FS_VERSION_SHORT"'/g' $FS_INSTALLDIR/banner.txt
sed -i 's/cms\.version/'"$FS_VERSION"'/g' $FS_INSTALLDIR/banner.txt
sed -i 's/jdk\.version/'"$JAVA_VERSION"'/g' $FS_INSTALLDIR/banner.txt
cp "$FS_INSTALLDIR/banner.txt" "$FS_BASEDIR/banner.txt"

cat $FS_BASEDIR/banner.txt

# Clean stalled PIDs
if [ "$1" = 'start' -a -f $FS_BASEDIR/run/fs-server.pid ];
    then
        rm $FS_BASEDIR/run/fs-server.pid;
fi

# Take ownership for fs5 user
echo "Taking care fs user owns firstspirit5 directory"
chown -R fs:fs $FS_BASEDIR

# Check if folders are mounted into container
if [ -d "$FS_BASEDIR/conf" ]
    then
        echo "Found firstspirit conf directory"
    else
        echo "No firstspirit conf directory found"
fi
if [ -d "$FS_BASEDIR/data" ]
    then
        echo "Found firstspirit data directory"
    else
        echo "No firstspirit data directory found"
fi
if [ -d "$FS_BASEDIR/web" ]
    then
        echo "Found firstspirit web directory"
    else
        echo "No firstspirit web directory found"
fi
if [ -d "$FS_BASEDIR/export" ]
    then
        echo "Found firstspirit export directory"
    else
        echo "No firstspirit export directory found"
fi
if [ -d "$FS_BASEDIR/log" ]
    then
        echo "Found firstspirit log directory"
    else
        echo "No firstspirit log directory found"
fi

# inject the external hostname if it exists
if [ -n "$EXT_HOSTNAME" ]; then
  sed -i "7i URL=$EXT_HOSTNAME" $FS_BASEDIR/conf/fs-server.conf
  echo "URL=$EXT_HOSTNAME written to fs-server.conf"
fi

# inject the external port if it exists
if [ -n "$EXT_PORT" ]; then
  sed -i "s/^HTTP_PORT=.*/HTTP_PORT=$EXT_PORT/" $FS_BASEDIR/conf/fs-server.conf
  echo "HTTP_PORT=$EXT_PORT written to fs-server.conf"
fi

# Create shared folder for local deployment tasks
mkdir -p /opt/www/html
chown -R fs:fs /opt/www

# Run FirstSpirit
su fs -c "$FS_BASEDIR/bin/fs-server $*"

exec tail -F $FS_BASEDIR/log/fs-wrapper.log $FS_BASEDIR/log/fs-server.log
