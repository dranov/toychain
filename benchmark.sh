#!/usr/bin/env bash
mkdir -p output/
for i in {001..005}
do
  ./node.native -me 127.0.0.1 2000 > output/a-$i.txt &
  ./node.native -me 127.0.0.1 2001 > output/b-$i.txt &
  ./node.native -me 127.0.0.1 2002 > output/c-$i.txt &
  ./node.native -me 127.0.0.1 2003 > output/d-$i.txt &
  sleep 10m
  ./kill.sh
done
