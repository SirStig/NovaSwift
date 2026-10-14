NovaSwift Dedicated Server
==========================
A standalone multiplayer server for NovaSwift. It needs no game and no EV Nova data.

Start it
  Windows : double-click "Start Server.bat"
  macOS   : double-click "Start Server.command" (or run ./NovaSwiftServer in Terminal)
  Linux   : ./NovaSwiftServer      (or use install-server.sh for a boot-time service)

It prints the admin panel address (http://localhost:53737) and an admin password ONCE. On a desktop your
browser opens on a first-run setup page by itself.

Open UDP 53735 and 53736 on your router / firewall so players can reach you. The panel's Network page helps.
Settings live in server.cfg next to this program. Options: NovaSwiftServer --help
Full guide: https://sirstig.github.io/NovaSwift/dedicated-server.html
