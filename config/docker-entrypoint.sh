#!/bin/sh

set -e

# Copy install files on first startup
if [ ! -f "$FS_BASEDIR/INSTALL_FILES_COPIED" ];
  then
    cp -r -n "$FS_INSTALLDIR/." "$FS_BASEDIR"
    touch "$FS_BASEDIR/INSTALL_FILES_COPIED"
fi

# If version in install dir is different from version in base dir then copy server files
cmp -s "$FS_INSTALLDIR/.version" "/$FS_BASEDIR/.version" || \
echo "Version files are different. Updating firstspirit server..." && \
cp -r "$FS_INSTALLDIR/server/." "$FS_BASEDIR/server" && \
cp -r "$FS_INSTALLDIR/bin/." "$FS_BASEDIR/bin" && \
cp "$FS_INSTALLDIR/.fs-rt.ver" "$FS_BASEDIR/.fs-rt.ver" && \
cp -r -n "$FS_INSTALLDIR/conf/." "$FS_BASEDIR/conf" && \
cp "$FS_INSTALLDIR/.version" "$FS_BASEDIR/.version"

cat /opt/firstspirit5/banner.txt

# Clean stalled PIDs
if [ "$1" = 'start' -a -f /opt/firstspirit5/run/fs-server.pid ];
    then
        rm /opt/firstspirit5/run/fs-server.pid;
fi

# Take ownership for fs5 user
echo "Taking care fs user owns firstspirit5 directory"
chown -R fs:fs /opt/firstspirit5

# Check if folders are mounted into container
if [ -d "/opt/firstspirit5/conf" ]
    then
        echo "Found firstspirit conf directory"
    else
        echo "No firstspirit conf directory found"
fi
if [ -d "/opt/firstspirit5/data" ]
    then
        echo "Found firstspirit data directory"
    else
        echo "No firstspirit data directory found"
fi
if [ -d "/opt/firstspirit5/web" ]
    then
        echo "Found firstspirit web directory"
    else
        echo "No firstspirit web directory found"
fi
if [ -d "/opt/firstspirit5/export" ]
    then
        echo "Found firstspirit export directory"
    else
        echo "No firstspirit export directory found"
fi
if [ -d "/opt/firstspirit5/log" ]
    then
        echo "Found firstspirit log directory"
    else
        echo "No firstspirit log directory found"
fi

# inject the external hostname if it exists
if [ -n "$EXT_HOSTNAME" ]; then
  sed -i "7i URL=$EXT_HOSTNAME" /opt/firstspirit5/conf/fs-server.conf
  echo "URL=$EXT_HOSTNAME written to fs-server.conf"
fi

# inject the external port if it exists
if [ -n "$EXT_PORT" ]; then
  sed -i "s/^HTTP_PORT=.*/HTTP_PORT=$EXT_PORT/" /opt/firstspirit5/conf/fs-server.conf
  echo "HTTP_PORT=$EXT_PORT written to fs-server.conf"
fi

# Create shared folder for local deployment tasks
mkdir -p /opt/www/html
chown -R fs:fs /opt/www

# Run FirstSpirit
su fs -c "/opt/firstspirit5/bin/fs-server $*"

exec tail -F /opt/firstspirit5/log/fs-wrapper.log /opt/firstspirit5/log/fs-server.log
