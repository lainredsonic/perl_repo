#!/usr/bin/env perl

use warnings;
use strict;

use LWP;
use HTML::LinkExtor;
use Parallel::ForkManager;
use Time::HiRes qw(gettimeofday tv_interval);
use Net::HTTP;
use Net::DNS;
use URI;

my $myurl;
my $locate="/";
my $ua="Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko) Chrome/27.0.1453.93 Safari/537.36";

if ($ARGV[0]){
	$myurl = $ARGV[0];
}else{
	$myurl = "http://www.cnbeta.com";
}

my $url = URI->new($myurl);
my $base_url = $url->host;

my $host_ip;
my $dns_res = Net::DNS::Resolver->new();
my $start_time = gettimeofday;
my $dns_query = $dns_res->query($base_url, "A");
my $latency = gettimeofday-$start_time;
print "DNS latency: $latency\n";
if ($dns_query){
	foreach ($dns_query->answer){
		if($_->type eq "A"){
			$host_ip = $_->address;
			last;	
		}
	}
}

exit until (defined $host_ip);

my $content;
$start_time = gettimeofday;
my $s = Net::HTTP->new(PeerAddr => $host_ip, Timeout => 10, KeepAlive => 1) || die $@;
$s->write_request(GET => $locate, 'User-Agent' => $ua, 'Host'=>$base_url);
my($code, $mess, %h) = $s->read_response_headers;
if ($code == 301 and $mess eq "Moved Permanently"){
	$locate	= $h{'Location'};
	print "relocation:$locate\n";
	if($locate =~ /^https{0,1}:\/\//){
		my $rel_locate = $';
		chop($rel_locate);
		$s = Net::HTTP->new(PeerAddr => $host_ip, Timeout => 10, KeepAlive => 1) || die $@;
		$s->write_request(GET => "/", 'User-Agent' => $ua, 'Host' => $rel_locate, KeepAlive => 1);
	}
}
#my $success = {$mess eq "ok"};
#exit until $success;
#print "header success:$success\n";

while (1) {
	my $buf;
	my $n = $s->read_entity_body($buf, 1024);
	die "read failed: $!" unless defined $n;
	last unless $n;
	$content .= $buf;
}
exit unless defined $content;

$latency = gettimeofday-$start_time;
print "header latency:$latency\n";


#my $parser = HTML::LinkExtor->new(undef, $base_url);
my $parser = HTML::LinkExtor->new(undef, undef);
$parser->parse($content)->eof;
my @links = $parser->links;
my @res;


foreach (@links) {
	my @element = @$_;
#	print "@element\n";
	my $elt_type = shift @element;
	next if($elt_type !~ /img|script/);
	my ($attr_name, $attr_value) = splice(@element, 0, 2);
	if ($attr_name eq "src"){
#		print "$elt_type $attr_name $attr_value\n";
		next if( $attr_value eq $base_url);
		if( $attr_value !~ /^http/){
			$attr_value = "http://".$base_url.$attr_value;
		}
		push(@res,$attr_value);
	}
}

my $browser = LWP::UserAgent->new();
$browser->agent($ua);
$browser->timeout(3);

my $thread = Parallel::ForkManager->new(20);
$start_time = gettimeofday;
foreach (@res){
	$thread->start and next;
	my $status = $browser->get($_)->status_line;
	print "status: $status $_\n";
	$thread->finish;
}
$thread->wait_all_children;
$latency = gettimeofday-$start_time;
print "flow latency:$latency\n";
