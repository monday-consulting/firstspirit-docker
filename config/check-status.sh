#!/bin/sh

# See https://docs.e-spirit.com/odfs/edocs/admi/firstspirit-ser/unix/index.html#runlevel
while ! grep -Fxq "$1" /opt/firstspirit5/.fs.lock; do
        state=$(sed -n '1p' /opt/firstspirit5/.fs.lock)
        echo "State is $state"
        sleep 10;
done
echo "FirstSpirit started!";