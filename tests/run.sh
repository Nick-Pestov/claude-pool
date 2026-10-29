#!/bin/bash
cd "$(dirname "$0")" && python3 -I test_claude_pool.py && python3 -I test_two_mac_sync.py
