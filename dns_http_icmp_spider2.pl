#! /usr/bin/env perl

use warnings;
use strict;

use URI;
use LWP;
use Net::DNS;
use Net::HTTP;
use HTML::LinkExtor;
use Parallel::ForkManager;
use Time::HiRes qw(gettimeofday tv_interval);

#use constant UA_CHROME		=> "Mozilla/5.0 AppleWebKit (KHTML, like Gecko) Chrome Safari";
my $UA_CHROME = "Mozilla/5.0 AppleWebKit (KHTML, like Gecko) Chrome Safari";

die "usage: $0 <uri>\n" unless defined $ARGV[0];

my $url = URI->new($ARGV[0]);

my ($host, $path, $query);

eval {
	$host = $url->host;
	$path = $url->path;
	$query = $url->query;
};

if ($@){
	print "malform url\n";
}

$path = "/" if($path eq "");


my ($host_ip, $dns_latency, $dns_success) = &p_dns($host);
print "$host_ip $dns_latency\n" if $dns_success;

my $ua = $UA_CHROME;
my $content;

my ($http_latency, $http_success) = &p_http($host_ip, $host, $path, $ua, \$content);

print $content," ",$http_latency,"\n";

sub p_dns {
	my $host = $_[0];
	my $host_ip;
	my $success = 0;
	my $dns_client = Net::DNS::Resolver->new(
			nameserver => [qw(8.8.8.8 8.8.4.4)],
			recurse => 1,
			retry => 3,
			dnsrch => 0,
			udp_timeout => 3,
			debug	=> 0
			);

	my $start_time = gettimeofday;
	my $dns_query = $dns_client->query($host, "A");
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
	my ($peer, $host, $path, $ua, $content) = @_;
	my $success = 0;
	my $start_time = gettimeofday;
	my $browser = Net::HTTP->new(
			'PeerAddr' => $peer,
			'Timeout' => 10,
			'KeepAlive' => 1,
			);

	$browser->write_request(
			'GET' => $path,
			'User-Agent' => $ua,
			'Host' => $host,
			);
	while (1){
		my $buf;
		my $n = $browser->read_entity_body($buf, 1024);
		die "read failed: $!" unless defined $n;
		last unless $n;
		$$content .= $buf;
	}
	my $latency = gettimeofday - $start_time;
	$success=1;
	($latency, $success);
}
