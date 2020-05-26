# rtir-scripts
Various small scripts that make life easier with RT(IR)

Author: Otmar Lendl, CERT.at

## Bulk Ticket Cleanup

Both scripts need a config file (default location ~/config.yml) which 
defines the parameters needed to connect to the RTIR server. It's in 
YAML format an should look something like this:

```
rtserver: "https://rtir.cert.at/rt/"
rtuser: "joe"
rttimeout: 30
cookiejar: "/home/joe/cookies"
```
On the first connect, use the -l option to ask for a password. The scripts
should save the session cookie so that -l is not needed for subsequent runs.

### Requirements

These scripts use RT::Client::REST to talk to the REST interface of RTIR.
On Debian, you need to install:

  libyaml-syck-perl librt-client-rest-perl liblog-log4perl-perl

(and perhaps some more dependencies)

### Common parameters

        -h: This help text
        -l: Initialize RTIR session (login)
        -c: config-file to use (defaults to ~/config.yml)

### merge_tool.pl

Sometimes the ticket-system receives multiple mails from a single e-mail
conversation where the subject does not contain a [RT #1234] tag. This often
happens if RTIR is Cc:'ed in e-mails or subscribed to a mailing-list.

RT cannot correlate the messages as part of a conversation and thus does not
collect all as correspondence inside a single ticket.

This tool can look for tickets in the same queue with similar subjects and
then offers the option to merge these tickets.

Options:

        -s: Look for tickets created after this date (defaults to one week ago)
        -q: Look in this queue (defaults to "CERT")

### cleanup_tool.pl

We all know that we should always keep an eye on our tickets and prompty
close all those incidents than can be closed. This can be a bit tedious as
one might need to check all associated Reports and Investigation tickets.
This tool simplifies that process.

cleanup_tool.pl search for open incidents, presents last communication from 
open reports and investigations and ask user which ones can be closed.

Options:

        -u: Look for incidents owned by this username (defaults to local user)
        -s: Look for tickets created after this date (defaults to unlimited)
        -e: Look for tickets created before this date (defaults: a week ago)
