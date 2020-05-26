#!/usr/bin/perl -w
#
# Merge tickets with (basically) the same subject
#
# Otmar Lendl <lendl@cert.at>, 2020/05/25
#

use strict;
use warnings;

use Error qw(:try);
use YAML::Syck;
use POSIX qw(strftime);
use Getopt::Long;
use RT::Client::REST 0.36;
use RT::Client::REST::Ticket;
use Term::ANSIColor qw(colored colorstrip);

use Log::Log4perl qw(:easy);
use Data::Dumper;

my $debug = 0;
my $configfile = $ENV{HOME} . "/config.yml";

my ($login, $help, $startdate, $queue);
$queue = "CERT";

GetOptions (   "d",   \$debug,
                "l",   \$login,
                "h",   \$help,
                "c=s", \$configfile,
                "s=s", \$startdate,
		"q=s", \$queue,
         ) or die usage();

if ($help) {
	print usage();
	exit 0;
}

# set the global debug level here, default: $INFO; for debugging: $DEBUG
Log::Log4perl->easy_init( { level => (($debug) ? $DEBUG : $INFO), layout => "[%d] [%c] [%p] %m%n" } );
my $log = Log::Log4perl->get_logger("$0");

my $config = YAML::Syck::LoadFile($configfile);

my $date_start =  strftime "%F", localtime(time - 7* 24* 3600); # default to one week

if (defined($startdate)) {
	if ($startdate =~ /^\d\d\d\d-\d\d-\d\d$/) {
		$date_start = $startdate;
	} else {
		$log->error("Invalid parameter for -s, needs to be YYYY-MM-DD\n");
		exit 1;
	}
}



my $shown_lines = 8;
my $rt;
my $t;

initialize($login);
my @tickets = fetch_tickets("queue = '$queue' and created >= '$date_start'", 
		'color' => 1,
                'no_create' => 1,
                'only_last' => 1);

my %groups = make_groups(\@tickets);

while (my ($s, $v) = each %groups) {
	my @ids = sort { $a <=> $b} keys(%$v);
	my $count = $#ids + 1;
	print "Subject '$s' has $count tickets.\n" if ($debug);

	if ($count > 1) {
		my $input = 'p';
		my $sum = "$count Tickets for Subject '$s'\n";
		foreach my $id (@ids) {
			my $t = $v->{$id};
			my $status = $t->{status};
			if ($status eq 'open') {
				$status = colored(['bold', 'on_yellow'],$t->{status});
			} elsif ($status eq 'resolved') {
				$status = colored(['bold', 'on_green'],$t->{status});
			} elsif ($status eq 'new') {
				$status = colored(['bold', 'on_magenta'],$t->{status});
			} elsif ($status eq 'rejected') {
				$status = colored(['bold', 'on_red'],$t->{status});
			}
			$sum .= "  $id $status " . $t->{reqs} . "  " . $t->{created} . "  " . $t->{subject} . "\n";
		}
		do {
			print "\n", $sum if ($input eq 'p');


			print "[p]rint, [i]gnore, [m]erge: ";
			$input = <STDIN>;
			chomp($input);
		} while ( $input !~ /^i|m$/ );

		if ($input eq 'm') {
			my $master = shift(@ids);
			while (my $id = shift(@ids)) {
				print STDERR "need to merge $id into $master\n";

# from the man page:
#       merge_tickets (src => $id1, dst => $id2)
#           Merge ticket $id1 into ticket $id2.

				try {
					print "Merging ..";
					$rt->merge_tickets(src => $id, dst => $master);
					print " .. done\n";
				} catch RT::Client::REST::Exception with {
					$log->error("Merge failed.");
				};

			}
		}
	}
}


exit 0;




##################################################################################
# 
# Utility subroutines

sub initialize {
	my $login = shift;

	my ($jar);
	my @jar_opt = ();

       # load credentials?
        if ($config->{cookiejar} and ( -r $config->{cookiejar})) {
                $jar = HTTP::Cookies->new(
                                ignore_discard => 1,
                                file => $config->{cookiejar},
                                autosave => 1); # this doesn't work as advertised, thus the manual save
                $jar->load();
                @jar_opt = ( _cookie => $jar );
        }

        # connect to RT
        $rt = RT::Client::REST->new(
                        server => $config->{rtserver},
                        timeout => $config->{rttimeout},
                        @jar_opt
                );

        # login with password?
        if ($login)  {
		my $password;
		print "Please enter RT password for user $config->{rtuser} on $config->{rtserver}: ";
		system('stty','-echo');
		chomp($password=<STDIN>);
		system('stty','echo');	
		print "\n";

		eval {
			$rt->login(username => $config->{rtuser},
				password => $password);
		};
		if($@) {
			die "Problem logging in: $@\n";
		};

                # store credentials?
                if ($config->{cookiejar}) {
                        $rt->{__cookie}->{ignore_discard} = 1;
                        $rt->{__cookie}->save( $config->{cookiejar});
                }
        }
}

#
# URL for tickets
#
sub id2url {
	my $id = shift;

	return("") unless ($id =~ /^\d+$/);

	return($config->{rtserver} . "/Ticket/Display.html?id=$id");
}


#
# Fetch matching tickets
#
sub fetch_tickets {
	my $restriction = shift;
	my %param = @_;
	my $incident;
	my @inv;
	my @rep;
	my %todo = ();
	my $sigint_received = 0;

	$restriction = '1 = 1' unless ($restriction);	# No, I don't worry about sqli here
	my $query = "(Status = 'open' or Status = 'resolved' or Status = 'new' or Status = 'rejected') and $restriction";

	$log->debug("Ticket Query: $query");
	my @candidates;
	my @tickets;

	eval {
		@candidates = $rt->search(
			type => 'ticket',
			query => $query,
			);
	};
	if($@) {
		die("Error looking for tickets ($@). Try $0 -l to login and get a session\n");
	}

	my $ticketcount = scalar(@candidates);
	print "Search found $ticketcount Tickets.\n";
	print "(", join(" ",@candidates), ")\n";

	$SIG{INT} = sub { $sigint_received = 1; print STDERR "\nAborting the fetching ...\n";};
	my $count = 1;
	foreach my $id (@candidates) {
		print "($count/$ticketcount) Looking at Ticket $id (^C to abort fetching)   \n";
		my $ticket = load_ticket($id);
		$count++;
		next unless ($ticket);

		push(@tickets, $ticket);

		last if ($sigint_received);
		}
	delete($SIG{INT});
	return(@tickets);
}


#
# load data for just one ticket.
#
sub load_ticket {
	my $ticket_id = $_[0];
	my $ticket;

eval {
        $ticket = RT::Client::REST::Ticket->new( rt => $rt, id => $ticket_id )->retrieve;
#	print "load_ticket ", Dumper($ticket);
};
if($@) {
        print STDERR "Error in load_ticket: $@";
}

	return($ticket);
}

sub make_groups {
	my $tickets = $_[0];

	my %res = ();

	foreach my $t (@$tickets) {
		my $subject = $t->subject;
		my $created = $t->created;
		my $status = $t->status;
		my $reqs = "";
			$reqs = join(", ", $t->requestors) if ($t->requestors);

#		print join(" ",$t->id, $created, $subject, $reqs), "\n";
		my %entry = (	created => $created,
				subject => $subject,
				reqs => $reqs,
				status => $status,
				id => $t->id,
			);

		my $skey = normalize_subject($subject);

		$res{$skey}{$t->id} = \%entry;
	}

#	print "Groups are: ", Dumper(\%res);

	return(%res);
}

sub normalize_subject {
	my $s = shift;

	my $res = $s;

	while( $res =~ s/\b(Re|AW|FW|WG|Fwd):\s*//) { 1; }	# replies, forwards, ...

	$res =~ s/^\s*//;	# leading whitespace
	$res =~ s/\s*$//;	# trailing whitespace
	$res =~ s/\s+/ /g;	# collapse whitespace
	
	$log->debug("Normalized $s to $res");
	return($res);
}


sub usage
{
	my $u = "Usage: $0 [-l] [-u username] [-s 2014-01-01] [-c file] [-q queue]\n\n";

$u .=<<EOF;
\tSearch for tickets with similar subjects in the same queue 
\tand ask user which ones should be merged.

\t-h: This help text
\t-l: Initialize RTIR session (login)
\t-c: config-file to use (defaults to ~/config.yml)
\t-s: Look for tickets created after this date (defaults to one week ago)
\t-q: Look in this queue (defaults to "CERT")

\tThe config-file is in YAML format and looks like this:

# RT client config
rtserver: "https://rtir.cert.example/rt"
rtuser: "johndoe"
rttimeout: 30
cookiejar: "/home/jd/.rtir_cookies"

EOF
	return $u;
}

