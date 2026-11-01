# Node setup and pairing

**Do this after Bitcoin Core has synced and electrs has finished indexing.** The electrs onion service stays off until then.
Run the node commands over your usual SSH session.

## 1. Get the phone's public key

Install the app and start setup. It generates a key and shows a line like:

```
descriptor:x25519:ABCDEF...
```

That line is public, so it's safe to copy or send to your Mac. The private half never leaves the phone's Keychain.

## 2. Enable the onion service

In `/etc/tor/torrc`, uncomment this section (it's in the `mini-pc` repo's `config/tor/torrc`):

```
HiddenServiceDir /var/lib/tor/electrs/
HiddenServicePort 50001 127.0.0.1:50001
HiddenServicePoWDefensesEnabled 1
```

Create the authorized client file **before** starting the service, so that the service is never published without client auth:

```sh
sudo install -d -o debian-tor -g debian-tor -m 700 /var/lib/tor/electrs /var/lib/tor/electrs/authorized_clients
echo 'descriptor:x25519:PASTE_THE_PHONE_KEY' | sudo -u debian-tor tee /var/lib/tor/electrs/authorized_clients/iphone.auth
sudo -u debian-tor chmod 600 /var/lib/tor/electrs/authorized_clients/iphone.auth
sudo runuser -u debian-tor -- tor --verify-config -f /etc/tor/torrc --quiet
sudo systemctl restart tor
sudo cat /var/lib/tor/electrs/hostname
```

This needs no firewall change, since Tor already has its outbound rule and `electrs` still only listens on loopback.

## 3. Update the node's audit baseline

You intentionally changed `torrc`, so the audit will flag it until you record a new baseline. From the `mini-pc` repo on the node:

```sh
sudo scripts/06-lock-down.sh
sudo node-audit
```

Expect `0 failed`, then copy the new baseline to your Mac as usual. `audit.sh` currently checks only the Bitcoin onion's key, so consider adding
`/var/lib/tor/electrs/hs_ed25519_secret_key` and `authorized_clients` to its watched files. That change also catches someone quietly adding a client.

## 4. Finish on the phone

Enter the address from `hostname`, then add the addresses you want to watch.

## Removing a phone

```sh
sudo rm /var/lib/tor/electrs/authorized_clients/iphone.auth
sudo systemctl restart tor
```

**If this is the last client file, Tor stops requiring client auth.** So comment out the service in `torrc` first, or replace the key in the same step instead of deleting the file.
