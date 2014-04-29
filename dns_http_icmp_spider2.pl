#! /usr/bin/env perl

use warnings;
use strict;
use 5.010;

use URI;
use LWP;
use Net::DNS;
use Net::HTTP;
use Net::Ping;
use Net::Traceroute::PurePerl;
use HTML::LinkExtor;
use Parallel::ForkManager;
use Time::HiRes qw(gettimeofday tv_interval);
use File::Stamped;
use Log::Minimal;

use constant MAX_SESSION	=> 100;
use constant MAX_REL		=> 5;
use constant RECV_TIMEOUT	=> 10;
use constant MAX_HTTP_PIPO	=> 10;
use constant UA_CHROME		=> "Mozilla/5.0 AppleWebKit (KHTML, like Gecko) Chrome Safari";

die "usage: $0 <uri>\n" unless defined $ARGV[0];

open (FD, "<", $ARGV[0]) or die "cannot open file\n";

my $logf = File::Stamped->new(pattern => 'log_%Y%m%d.txt');
local $Log::Minimal::PRINT = sub {
	my($time, $type, $message, $trace) = @_;
	print {$logf} "$time [$type] $message at $trace\n";
};

my @line = <FD>;

my $session = Parallel::ForkManager->new(MAX_SESSION);
print "url|dns_latency|dns_success|host_ip|icmp_latency|icmp_success|http_latency|http_success|http2_latency\n";

foreach (@line){
	$session->start and next;
	chomp($_);
	$_ = 'http://'.$_ if ($_ !~ /^http:\/\//);
	&p_main($_);
	$session->finish;
}

$session->wait_all_children;



sub p_main{
	my $url = URI->new($_[0]);

	my ($host, $path, $query);

	eval {
		$host = $url->host;
		$path = $url->path;
		$query = $url->query;
	};

	if ($@){
		die "malform url $_[0]\n";
	}

	my ($full_url,
		$dns_latency, $dns_success, $host_ip, 
		$icmp_latency, $icmp_success, 
		$http_latency, $http_success, 
		$http2_latency, $http2_success, @hops);

	$full_url = $_[0];

	$path = "/" if($path eq "");

################## DNS query #####################
	($host_ip, $dns_latency, $dns_success) = &p_dns($host);
=head
	if($dns_success){
		print "DNS: $host_ip $dns_latency\n";
	}else{
		die "dns failed\n";
	}
=cut
	warnf "dns failed $host" unless $dns_success;
##################################################

################## ICMP test #####################
	($icmp_latency, $icmp_success) = &p_icmp($host_ip);
#	print "ICMP: $icmp_latency\n" if $icmp_success;
##################################################

################## HTTP portal ###################
	my $ua = UA_CHROME;

	my $content;
	my $true_host;

	($http_latency, $http_success) = &p_http($host_ip, $host, $path, $ua, \$content, \$true_host);
=head
	if ($http_success and defined $content){
#	print "HTTP_PORTAL: $content,$http_latency\n";
		print "HTTP_PORTAL: $http_latency\n";
	}else{
		die "http failed\n";
	}
=cut
	die "######## http failed: $host\n" unless ($http_success);
##################################################

################# HTTP 2 #########################

	$host = $true_host if defined $true_host;
	($http2_success, $http2_latency) = &p_http_2(\$content, $ua, $host);
=head
	if ($http2_success){
		print "HTTP_FLOW: $http2_latency\n";
	}else{
		die "http flow failed\n";
	}
=cut
	die "######## http flow failed: $host\n" unless $http2_success;

##################################################

################# TRACEROUTE #####################
#	&p_traceroute($host_ip, \@hops);


##################################################
	printf "%s|%.2f|%d|%s|%.2f|%d|%.2f|%d|%.2f\n", 
		$full_url,$dns_latency,$dns_success,
		$host_ip,$icmp_latency,$icmp_success,
		$http_latency,$http_success,$http2_latency;

	foreach (@hops){
		print $_;
	}
}

sub p_dns {
	my $host = $_[0];
	my $host_ip;
	my $success = 0;
	my $dns_client;
	my $start_time;
	my $dns_query;
	eval {
		$dns_client = Net::DNS::Resolver->new(
				nameserver => [qw(8.8.8.8 8.8.4.4)],
				recurse => 1,
				retry => 3,
				dnsrch => 0,
				udp_timeout => 3,
				debug	=> 0
				);
		$start_time = gettimeofday;
		$dns_query = $dns_client->query($host, "A");
	};
	if ($@){
		return (0, 0, 0);
	}

	my $latency = gettimeofday - $start_time;
	if ($dns_query){
		foreach ($dns_query->answer){
			if ($_->type eq "A"){
				$host_ip = $_->address;
				$success = 1;
				last;
			}
		}
	}
	($host_ip, $latency, $success);
}

sub p_http{
	my ($peer, $host, $path, $ua, $content, $true_host) = @_;
	my $success = 0;
	state $depth = 0;
	if ($depth > MAX_REL){
		warnf "maxium relocation reached";
		return (0, 0);
	}
	$depth++;
	my $start_time = gettimeofday;
	my ($browser, $code, $mess, %h);
	eval {
		$browser = Net::HTTP->new(
				'PeerAddr' => $peer,
				'Timeout' => 10,
				'KeepAlive' => 0,
				);

		$browser->write_request(
				'GET' => $path,
				'User-Agent' => $ua,
				'Host' => $host,
				);
		($code, $mess, %h) = $browser->read_response_headers;
		while (1){
			my $n;
			my $buf;
			eval {
				local $SIG{ALRM} = sub { warnf "receive p_http timeout"; };
				alarm RECV_TIMEOUT;
				$n = $browser->read_entity_body($buf, 1024);
				alarm 0;
			};
			last unless $n;
			$$content .= $buf;
		}
	};
	if ($@){
		warnf "http request failed: $@"; 
	}else{
		$success=1;
		if ($code == 301 and $mess eq "Moved Permanently"){
			my $location = $h{'location'};
			my $Location = $h{'Location'};
			if(defined $Location and $Location =~ /^https{0,1}:\/\/([0-9a-zA-Z_\-\.]*)/){
				$Location = $1;
				warnf "Location: $Location";
				&p_http($peer, $Location, $path, $ua, $content, $true_host);
				${$true_host} = $Location;
			}elsif(defined $location){
				warnf "location: $location";
				$location ="/".$location;
				&p_http($peer, $host, $location, $ua, $content, $true_host);
			}else{
				warnf "status 301, but unknown location";
				$success=0;
			}
		}
	}
	my $latency = gettimeofday - $start_time;
	($latency, $success);
}

sub p_icmp{
	my $icmp_client = Net::Ping->new('icmp');
	my $success = 0;
	$icmp_client->hires();
	my ($ret, $duration, $ip) = $icmp_client->ping($_[0], 3);
	if ($ret){
		$success = 1;
	}else{
		warnf "ICMP failed";
	}
	$icmp_client->close();
	($duration, $success);
}

sub p_http_2{
	my $content = ${$_[0]};
	my $ua = $_[1];
	my $base_host = $_[2];
	my $success = 0;
	return (0, 0) if(!defined $content or $content eq "");
	my $parser = HTML::LinkExtor->new();
	$parser->parse($content)->eof;
	my @links = $parser->links;
	my @res;
	
	foreach (@links){
		my @element = @$_;
		my $elt_type = shift @element;
		next if ($elt_type !~ /img|script/);
		my ($attr_name, $attr_value) = splice(@element, 0, 2);
		if($attr_name eq "src"){
			push (@res, $attr_value);
		}
	}

	my %g_res;
	foreach (@res){
		if ($_ =~ /^https{0,1}:\/\/([0-9a-zA-Z_\-\.]*)\//){
			my $src_host = $1;
			$g_res{$src_host} .= "$_ ";
		}else{
#			print "not grouped: $_\n";
			my $src_host = "http://".$base_host."/".$_;
			$g_res{$base_host} .= "$src_host ";
		}
	}

	my $bua = LWP::UserAgent->new('keep_alive' => 20);
	$bua->agent($ua);
	$bua->timeout(3);

	my $thread = Parallel::ForkManager->new(MAX_HTTP_PIPO);

	my $start_time = gettimeofday;

	my @key = keys %g_res;
	foreach (@key){
		my @link = split(/ /,$g_res{$_});
		$thread->start and next;
		foreach (@link){
			eval {
				local $SIG{ALRM} = sub { warnf "receive p_http_2 timeout"; };
				alarm RECV_TIMEOUT;
				my $status = $bua->get($_)->status_line;
#				print "status: $status $_\n";
				alarm 0;
			};
		}
		$thread->finish;
	}
	$thread->wait_all_children;
	$success = 1;
	my $latency = gettimeofday-$start_time;
	($success, $latency);
}

sub p_traceroute{
	my $tr = Net::Traceroute::PurePerl->new(host => $_[0], max_ttl => 128, protocol => 'icmp', query_timeout => 2);
	my $hops_list = $_[1];
	$tr->traceroute;
	if($tr->found){
		my $hops = $tr->hops;
		my $i;
		for($i=1; $i <= $hops; $i++){
			my $ip = $tr->hop_query_host($i, 0);
			$ip = "NULL" unless defined $ip;
			if($i == $hops){
				push(@{$hops_list}, "$ip\n");
			}else{
				push (@{$hops_list}, "$ip => ");
			}
		}
	}
}
