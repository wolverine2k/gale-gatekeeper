#!/bin/sh
#
# The MIT License (MIT)
# Copyright (c) 2026 Naresh Mehta (https://www.naresh.se/)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

# dnsmasq_trigger.sh - Minimal trigger script for dnsmasq events
# This script is called by dnsmasq when DHCP events occur and sends ubus events
# for the gatekeeper system to process. It requires no external libraries.
#
# Usage: Called automatically by dnsmasq with parameters:
#   $1 - action (e.g., "add", "old", "del")
#   $2 - MAC address
#   $3 - IP address  
#   $4 - hostname
#
# Maintenance Notes:
# - Keep this script minimal to avoid dependencies issues
# - This bridges dnsmasq DHCP events to ubus messages
# - Error handling is intentionally minimal to prevent dnsmasq failures

# Send ubus event with DHCP information for gatekeeper processing
ubus send dnsmasq.event "{\"action\":\"$1\",\"mac\":\"$2\",\"ip\":\"$3\",\"host\":\"$4\"}"
