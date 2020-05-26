#!/usr/bin/perl -w
#
# Cleaning up old incidents
#
# Otmar Lendl <lendl@cert.at>, 2014/07/17
#

use strict;
use warnings;

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

my ($login, $help, $user, $startdate, $enddate);

GetOptions (   "d",   \$debug,
                "l",   \$login,
                "h",   \$help,
                "c=s", \$configfile,
                "u=s", \$user,
                "s=s", \$startdate,
                "e=s", \$enddate,
         ) or die usage();

if ($help) {
	print usage();
	exit 0;
}

# set the global debug level here, default: $INFO; for debugging: $DEBUG
Log::Log4perl->easy_init( { level => (($debug) ? $DEBUG : $INFO), layout => "[%d] [%c] [%p] %m%n" } );
my $log = Log::Log4perl->get_logger("$0");

my $config = YAML::Syck::LoadFile($configfile);

my $date_start = '0000-01-01';
if (defined($startdate)) {
	if ($startdate =~ /^\d\d\d\d-\d\d-\d\d$/) {
		$date_start = $startdate;
	} else {
		$log->error("Invalid parameter for -s, needs to be YYYY-MM-DD\n");
		exit 1;
	}
}

my $date_end = strftime("%Y-%m-%d", localtime(time - 7 * 24 * 3600));
if (defined($enddate)) {
	if ($enddate =~ /^\d\d\d\d-\d\d-\d\d$/) {
		$date_end = $enddate;
	} else {
		$log->error("Invalid parameter for -e, needs to be YYYY-MM-DD\n");
		exit 1;
	}
}

my $rtiruser = $user || $config->{rtuser} || $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);

die "Illegal username ($rtiruser) specified" unless ($rtiruser =~ /^[\w-]*$/);

my $shown_lines = 8;
my $rt;
my $t;

initialize($login);
my %todo = incidents_to_close("owner = '$rtiruser' and created >= '$date_start' and created <= '$date_end'", 
		'color' => 1,
                'no_create' => 1,
                'only_last' => 1);

my @to_close = ask_to_close(\%todo);

print "You decided to close: ", join(", ",@to_close), "\n";

foreach my $id (@to_close) {
	$| = 1;
	print "Closing $id ...";
	my $ticket = RT::Client::REST::Ticket->new(
           rt  => $rt,
           id  => $id,
           status => "resolved",
         )->store;
	print " ...\n";
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
# Look for Incidents with no open Member tickets
#
sub incidents_to_close {
	my $restriction = shift;
	my %param = @_;
	my $incident;
	my @inv;
	my @rep;
	my %todo = ();
	my $sigint_received = 0;

	$restriction = '1 = 1' unless ($restriction);	# No, I don't worry about sqli here
	my $query = "Queue = 'Incidents' and Status = 'open' and $restriction";

	$log->debug("Ticket Query: $query");
	my @candidates;

	eval {
		@candidates = $rt->search(
			type => 'ticket',
			query => $query,
			);
	};
	if($@) {
		die("Error looking for tickets ($@). Try $0 -l to login and get a session\n");
	}

	print "Search found ", scalar(@candidates), " open incidents.\n";
	print "(", join(" ",@candidates), ")\n";

	$SIG{INT} = sub { $sigint_received = 1; print STDERR "\nAborting the fetching ...\n";};
	foreach my $id (@candidates) {
		print "Looking at Incident $id (^C to abort fetching)\n";
		$incident = load_incident($id);
		next unless ($incident);

		@rep = (exists($incident->{'Incident Reports'})) ? @{$incident->{'Incident Reports'}} : ();
		@inv = (exists($incident->{'Investigations'})) ? @{$incident->{'Investigations'}} : ();

		print "Incident $id has open: ", scalar(@rep), " Reports, ", scalar(@inv), " Investigations.\n";
		$todo{$id} = summarize_incident($incident, %param);
		last if ($sigint_received);
		}
	delete($SIG{INT});
	return(%todo);
}

#
# Load data for Incident + open Member-tickets
#
sub load_incident {
	my $ticket_id = $_[0];

# the ticket itself;
#print "Loading base ticket $ticket_id\n";
        my $ticket = load_leaf_ticket($ticket_id);
	return(undef) unless ($ticket);

	if ($ticket->queue ne 'Incidents') {
		print STDERR "Ticket $ticket_id is not an Incident\n";
		return undef;
	}


	my @ids = $rt->search(
		type => 'ticket',
		query => "Status = 'open' and MemberOf = '$ticket_id'",
	 );

	my ($member_ticket, $queue);
	foreach my $member (@ids) {
		$member_ticket = load_leaf_ticket($member);
		next unless ($member_ticket);
		$queue = $member_ticket->queue();

		push(@{$ticket->{$queue}}, $member_ticket);
	}
#	print Dumper($ticket);
	return($ticket);
}



#
# load data for just one ticket.
#
sub load_leaf_ticket {
	my $ticket_id = $_[0];
	my $ticket;

eval {
        $ticket = RT::Client::REST::Ticket->new( rt => $rt, id => $ticket_id )->retrieve;
	my $result = $ticket->transactions(type => [qw(Comment Correspond Create)]);

#	print "Ticket $ticket_id has ", $result->count(), " transactions\n";
	my $iterator = $result->get_iterator;
	my @transactions = &$iterator;

	$ticket->{'Actions'} = \@transactions;

#	print "load_leaf_ticket ", Dumper($ticket, \@transactions);
};
if($@) {
        print STDERR "Error in load_leaf_ticket: $@";
}

	return($ticket);
}

sub summarize_incident {
	my $i = shift;
	my %param = @_;

	my $i_text = summarize_ticket($i, %param);
	my $i_id = $i->id;

	my %rep = ();
	foreach my $rep (@{$i->{'Incident Reports'}}) {
		$rep{$rep->id} = summarize_ticket($rep, %param);
	}

	my %inv = ();
	foreach my $inv (@{$i->{'Investigations'}}) {
		$inv{$inv->id} = summarize_ticket($inv, %param);
	}
	
	my $res = "=================================\n";
	$res .= $i_text;
	$res .= colored(['bold', 'on_red'], "===== Incident Reports ====="). "\n";
	foreach (values(%rep)) {
		$res .= "------------\n$_\n";
	}
	$res .= colored(['bold', 'on_red'], "===== Investigations ====="). "\n";
	foreach (values(%inv)) {
		$res .= "------------\n$_\n";
	}

	return( ($param{color}) ? $res : colorstrip($res) );	
}

#
#	params:
#
#		only_last
#		no_create
#		color
#
sub summarize_ticket {
	my $t = shift;
	my %param = @_;

	return("") unless ($t);

	my $res = "Ticket: " .  colored(['bold', 'bright_cyan'],$t->id) . "/" . $t->status ."/" . $t->owner . "/" . $t->created . "\n";
	$res .= "Link: " .  colored(['bold', 'black', 'on_bright_white'],id2url($t->id)) . "\n";
	$res .= "Requestors: " . join(", ", $t->requestors) . "\n" if ($t->requestors);
	$res .= "Subject: " . colored(['bold', 'bright_yellow'],$t->subject) . "\n\n";

# actions ..
	my @a = sort { $a->id <=> $b->id } (@{$t->{Actions}});
# filter ...
	@a = grep { $_->content ne 'This transaction appears to have no content'  } @a;
	@a = grep {  !($param{'no_create'} and ($_->type eq 'Create')) } @a;
	while ($param{'only_last'} and ($#a > 0))
		{ shift(@a); }
	foreach my $a (@a) {
#		print Dumper($a), "\n\n";
		$res .= "-------------\nAction: " . $a->type . " / " . $a->created . "\n";
		$res .= "Cc: " . join(", ", $t->cc) . "\n" if ($t->cc);
		$res .= "\n" . string_head(strip_quotes($a->content),10);
	}
	return($res);	
}

sub sort_actions {
	$a->id <=> $b->id;
}

sub strip_quotes {
	my $s = $_[0];

	$s =~ s/\n-- .*//s;	# remove signatures
	$s =~ tr/\r//d;		# remove CR
	$s =~ s/^On .* wrote:$//mg;	# quote start
	$s =~ s/^>.*$//mg;	# quoted lines
	$s =~ s/^\s+$//mg;	# whitespace only lines
	$s =~ s/\s+$//mg;	# tailing whitespace 
	$s =~ s/\n+/\n/sg;	# remove double empty lines
	$s =~ s/^\n+//sg;	# remove newline at start

	return($s);
}

sub string_head
{
	my ($s, $count) = @_;
	my $rval = "";
	my $i = 0;
	foreach my $line (split(/\n/, $s))
	{
		$line =~ s/\r|\n//g;
		$rval .= "$line\n";
		$i++;
		if($i == $count)
		{
			$rval .= "...\n";
			last;
		}
	}
	return $rval;
}

sub ident
{
	my ($s, $ident) = @_;
	my $rval = "";
	foreach my $line (split(/\n/, $s))
	{
		$line =~ s/\r|\n//g;
		$rval .= " "x$ident;
		$rval .= "$line\n";
	}
	return $rval;
}

sub ask_to_close {
	my $todo = shift;

	my $total = scalar(keys(%$todo));
	my $count = 1;

	my $clear = `clear`;

	my ($id, $text, $input);
	my @to_close = ();

	while (($id, $text) = each %$todo) {
		$input = 'p';
		do {
			print $clear, "$count/$total (", scalar(@to_close)," marked)\n$text" if ($input eq 'p');


			print "[p]rint, [c]lose, [s]kip, [f]inish or [a]bort: ";
			$input = <STDIN>;
			chomp($input);
		} while ( $input !~ /^c|s|f|a$/ );
		if ($input eq 'c') {
			print "Remembering to close $id\n";
			push @to_close, $id;
		}
		if ($input eq 'f') {
			print "Finishing for now ...\n";
			return(@to_close);
		}
		if ($input eq 'a') {
			print "Aborting ...\n";
			return();
		}
		$count++;
	}
	return(@to_close);
}


sub usage
{
	my $u = "Usage: $0 [-l] [-u username] [-s 2014-01-01] [-e 2014-02-01]\n\n";

$u .=<<EOF;
\tSearch for open incidents, present last communication from open reports and
\tinvestigations and ask user which ones can be closed.

\t-h: This help text
\t-l: Initialize RTIR session (login)
\t-c: config-file to use (defaults to ~/config.yml)
\t-u: Look for incidents owned by this username (defaults to local user)
\t-s: Look for tickets created after this date (defaults to unlimited)
\t-e: Look for tickets created before this date (defaults: a week ago)

\tThe config-file is in YAML format and looks like this:

# RT client config
rtserver: "https://rtir.cert.example/rt"
rtuser: "johndoe"
rttimeout: 30
cookiejar: "/home/jd/.rtir_cookies"

EOF
	return $u;
}

