#!/bin/bash
cd "$(dirname "$0")"
./NovaSwiftServer
echo; echo "The server stopped. Press Return to close."; read
