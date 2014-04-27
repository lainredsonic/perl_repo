#! /usr/bin/env perl

use warnings;
use strict;
use 5.010;

use URI;
use LWP;
use Net::DNS;
use Net::HTTP;
use Net::Ping;
use HTML::LinkExtor;
use Parallel::ForkManager;
use Time::HiRes qw(gettimeofday tv_interval);

use constant MAX_REL		=> 5;
use constant MAX_HTTP_PIPO	=> 10;
use constant UA_CHROME		=> "Mozilla/5.0 AppleWebKit (KHTML, like Gecko) Chrome Safari";

die "usage: $0 <uri>\n" unless defined $ARGV[0];

my $url = URI->new($ARGV[0]);

my ($host, $path, $query);

eval {
	$host = $url->host;
	$path = $url->path;
	$query = $url->query;
};

if ($@){
	die "malform url\n";
}

$path = "/" if($path eq "");

################## DNS query #####################
my ($host_ip, $dns_latency, $dns_success) = &p_dns($host);
if($dns_success){
	print "DNS: $host_ip $dns_latency\n";
}else{
	die "dns failed\n";
}
##################################################

################## ICMP test #####################
my ($icmp_latency, $icmp_success) = &p_icmp($host_ip);
print "ICMP: $icmp_latency\n" if $icmp_success;
##################################################

################## HTTP portal ###################
#my $ua = $UA_CHROME;
my $ua = UA_CHROME;

my $content;

my ($http_latency, $http_success) = &p_http($host_ip, $host, $path, $ua, \$content);
if ($http_success){
#	print "HTTP_PORTAL: $content,$http_latency\n";
	print "HTTP_PORTAL: $http_latency\n";
}else{
	die "http failed\n";
}
##################################################

################# HTTP 2 #########################

my ($http2_success, $http2_latency) = &p_http_2(\$content, $ua);
if ($http_success){
	print "HTTP_FLOW: $http2_latency\n";
}else{
	die "http flow failed\n";
}

##################################################

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
		warn "dns request failed\n"; 
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
	my ($peer, $host, $path, $ua, $content) = @_;
	my $success = 0;
	state $depth = 0;
	if ($depth > MAX_REL){
		warn "maxium relocation reached\n";
		return;
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
			my $buf;
			my $n = $browser->read_entity_body($buf, 1024);
			last unless $n;
			$$content .= $buf;
		}
	};
	if ($@){
		warn "http request failed: $@\n"; 
	}else{
		$success=1;
		if ($code == 301 and $mess eq "Moved Permanently"){
			my $location = $h{'location'};
			my $Location = $h{'Location'};
			if(defined $Location and $Location =~ /^https{0,1}:\/\/([0-9a-zA-Z_\-\.]*)/){
				$Location = $1;
				warn "Location: $Location\n";
				&p_http($peer, $Location, $path, $ua, $content);
			}else{
				warn "location: $location\n";
				$location ="/".$location;
				&p_http($peer, $host, $location, $ua, $content);
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
	}
	$icmp_client->close();
	($duration, $success);
}

sub p_http_2{
	my $content = ${$_[0]};
	my $ua = $_[1];
	my $success = 0;
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
#			next if($attr_value eq $base_url);
#			$attr_value = "http://".$base_url.$attr_value;
#				if($attr_value !~ /^http/);
			push (@res, $attr_value);
=head
			foreach (@res){
				print "$_\n";
			}
=cut
		}
	}

	my %g_res;
	foreach (@res){
		if ($_ =~ /^https{0,1}:\/\/([0-9a-zA-Z_\-\.]*)\//){
			my $src_host = $1;
			$g_res{$src_host} .= "$_ ";
		}else{
			print "not grouped $_\n";
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
			my $status = $bua->get($_)->status_line;
			print "status: $status $_\n";
		}
		$thread->finish;
	}
	$thread->wait_all_children;
	$success = 1;
	my $latency = gettimeofday-$start_time;
	($success, $latency);
}
