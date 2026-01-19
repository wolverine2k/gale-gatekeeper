#!/bin/sh
# Minimal trigger - no libraries needed
ubus send dnsmasq.event "{\"action\":\"$1\",\"mac\":\"$2\",\"ip\":\"$3\",\"host\":\"$4\"}"
