#!/usr/bin/perl

# AbbDataLogger - Webservices datalogger for IO and persdata on Abb robotcontrollers
# Copyright (C) 2026 Sigmund Straumland
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
	
	
	
use strict;
use warnings;

use Getopt::Long;
use Config::Tiny;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use LWP::UserAgent;
use HTTP::Cookies;
use AnyEvent::WebSocket::Client;
use MIME::Base64;
use XML::LibXML;
use Time::HiRes qw(gettimeofday);

$| = 1;



# -------------------------
# Config file
# -------------------------

my $Config = Config::Tiny->read('DataLogger.ini', 'utf8');
my $server_ip = $Config->{connection}->{server_ip};
my $server_port = $Config->{connection}->{server_port};
my $server_https = $Config->{connection}->{https};
my $server_username = $Config->{connection}->{username};
my $server_password = $Config->{connection}->{password};
my $file_server_resources = $Config->{files}->{file_server_resources};
my $file_listen_resources = $Config->{files}->{file_listen_resources};



# -------------------------
# CLI arguments
# -------------------------

my $arg_file_log = '';
my $arg_list_resources = '';
my $arg_reset_config = '';
my $arg_short_naming = '';
GetOptions(
    "list_resources" => \$arg_list_resources,
    "reset_config" => \$arg_reset_config,
	"short_naming" => \$arg_short_naming,
    "log=s" => \$arg_file_log,
);



# -------------------------
# New default config file
# -------------------------

if ($arg_reset_config) {
    my $Config_new = Config::Tiny->new({
        connection => {
			server_ip => '192.168.125.1',
			server_port => '443',
			https => '1',
			username => 'Default User',
			password => 'robotics'
		},
        files => {
			file_server_resources => 'ServerResources.txt',
			file_listen_resources => 'ListenResources.txt'
		}
    });
    $Config_new->write('DataLogger.ini', 'utf8') or die 'Could not create new default config file' . "\n";
    print 'New default config file created.' . "\n";
    exit;
}



# -------------------------
# REST client
# -------------------------

# New useragent
my $ua = LWP::UserAgent->new( timeout => 10, cookie_jar => HTTP::Cookies->new() );

# Ignore TLS certificates
$ua->ssl_opts(
    SSL_verify_mode => SSL_VERIFY_NONE,
    verify_hostname => 0,
);

sub http_request {
    my($method, $path, $body, $args) = @_;

    my %object;

    my $start;
    my $limit;

    my $baseurl = $Config->{connection}->{https} ? 'https://' . $server_ip . ':' . $server_port : 'http://' . $server_ip . ':' . $server_port;

    my $i_tasks = 0;
    my $i_signals = 0;
    my $i_persdata = 0;

    while (1) {

		my $url = $baseurl . $path;
		$url .=  ($start ? ($url =~ /\?/ ? '' : '?') . 'start=' . $start : '');
		$url .=  ($limit ? ($url =~ /\?/ ? '' : '?') . 'limit=' . $limit : '');

		my $xhtml;
        if ($method eq 'get') {
            $xhtml = http_get($url);
        } elsif ($method eq 'post') {
            $xhtml = http_post($url, $body);
        } else {
            die 'Invalid method for http request';
        }

		# Parse XML
		my $dom = XML::LibXML->load_xml(string => $xhtml);

		# XPath context with XHTML namespace
		my $xpc = XML::LibXML::XPathContext->new($dom);
		$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

        my($div_class_state) = $xpc->findnodes('//x:div[@class="state"]');

        # Websocket url
        my($websocket_url) = $xpc->findnodes('.//x:a[@rel="self"]', $div_class_state);
		$object{a_rel_self} = $websocket_url->getAttribute('href');

        # Next link
        my($next) = $xpc->findnodes('.//x:a[@rel="next"]', $div_class_state);

        # RobotId
        my($ctrl_name) = $xpc->findnodes('.//x:span[@class="ctrl-name"]', $div_class_state);
        my($ctrl_id) = $xpc->findnodes('.//x:span[@class="ctrl-id"]', $div_class_state);
		$object{span_ctrl_name} = $ctrl_name->textContent if (defined $ctrl_name);
		$object{span_ctrl_id} = $ctrl_id->textContent if (defined $ctrl_id);

        # List reference
        my($ul) = $xpc->findnodes('.//x:ul', $div_class_state);	

        # robotware
        my($ul_li_class_sys_system) = $xpc->findnodes('.//x:li[@class="sys-system"]', $ul);
        my($robotware) = $xpc->findnodes('.//x:span[@class="rwversionname"]', $ul_li_class_sys_system);
        my($robotware_build) = $xpc->findnodes('.//x:span[@class="build"]', $ul_li_class_sys_system);
		$object{ul_li_class_sys_system_span_class_rwversionname} = $robotware->textContent if (defined $robotware);
		$object{ul_li_class_sys_system_span_class_build} = $robotware_build->textContent if (defined $robotware_build);

        # Tasks
        for my $li ($xpc->findnodes('.//x:li[@class="rap-task-li"]', $ul)) {
            my($task_resource) = $xpc->findnodes('.//x:span[@class="name"]', $li);
			$object{ul_li_rap_rask_li_span_class_name}[$i_tasks] = $task_resource->textContent;
			$i_tasks++;
		}

        # IO list
        for my $li ($xpc->findnodes('.//x:li[@class="ios-signal-li"]', $ul)) {
            my($sig_resource) = $xpc->findnodes('.//x:a[@rel="self"]', $li);
			$object{ul_li_ios_signal_li_a_rel_self}[$i_signals] = '/rw/iosystem/' . $sig_resource->getAttribute('href') . ';state';
			$i_signals++;
		}

        # Persdata
        for my $li ($xpc->findnodes('.//x:li[@class="rap-symproppers-li"]', $ul)) {
            my($pers_resource) = $xpc->findnodes('.//x:span[@class="symburl"]', $li);
			$object{ul_li_rap_symproppers_li_span_class_symburl}[$i_persdata] = '/rw/rapid/symbol/' . $pers_resource->textContent . '/data;value';
			$i_persdata++;
		}

   		last unless $next;

		# Parse next start index from href
		$start = $1 if ($next =~ /start=(\d+)/);
		$limit = $1 if ($next =~ /limit=(\d+)/);
    }

	return %object;
}

sub http_get {
    my($url) = @_;

    my $header_accept = 'application/xhtml+xml;v=2.0';
    my $header_authorization = 'Basic ' . encode_base64($Config->{connection}->{username} . ':' . $Config->{connection}->{password} . '');

    my $req = HTTP::Request->new(
        GET => $url,
        [
            'Accept' => $header_accept,
            'Authorization' => $header_authorization,
        ],
    );

    $ua->cookie_jar->add_cookie_header($req);
    my $res = $ua->request($req);

    unless ($res->is_success) {
    die 'GET request failed: ' . $url . "\n"
        . "Status: " . $res->status_line . "\n"
        . "Request:\n" . $req->as_string . "\n"
        . "Response headers:\n" . $res->headers_as_string . "\n"
        . "Response body:\n" . $res->decoded_content . "\n";
	}

    return $res->decoded_content;
}

sub http_post {
    my($url, $body) = @_;

    my $header_accept = 'application/xhtml+xml;v=2.0';
    my $header_content_type = 'application/x-www-form-urlencoded;v=2.0';
    my $header_authorization = 'Basic ' . encode_base64($Config->{connection}->{username} . ':' . $Config->{connection}->{password} . '');

    my $req = HTTP::Request->new(
        POST => $url,
        [
            'Accept' => $header_accept,
            'Content-type' => $header_content_type,
            'Content-length' => length($body),
            'Authorization' => $header_authorization,
        ],
        $body
    );

    $ua->cookie_jar->add_cookie_header($req);
    my $res = $ua->request($req);

    unless ($res->is_success) {
    die 'POST request failed: ' . $url . "\n"
        . "Status: " . $res->status_line . "\n"
        . "Request:\n" . $req->as_string . "\n"
        . "Response headers:\n" . $res->headers_as_string . "\n"
        . "Response body:\n" . $res->decoded_content . "\n";
	}

    return $res->decoded_content;
}



# -------------------------
# List resources
# -------------------------

sub list_resources {
    my @resources;

	print 'Requesting /rw/iosystem/signals...';
	my %data_io = http_request('get', '/rw/iosystem/signals');
	print 'found ' . (defined $data_io{ul_li_ios_signal_li_a_rel_self} ? scalar(@{$data_io{ul_li_ios_signal_li_a_rel_self}}) : '0') . ' signals' . "\n";
	push(@resources, (defined $data_io{ul_li_ios_signal_li_a_rel_self} ? @{$data_io{ul_li_ios_signal_li_a_rel_self}} : ()));

	print 'Requesting /rw/rapid/tasks...';
	my %data_tasks = http_request('get', '/rw/rapid/tasks');
	print 'found ' . (defined $data_tasks{ul_li_rap_rask_li_span_class_name} ? scalar(@{$data_tasks{ul_li_rap_rask_li_span_class_name}}) : '0') . ' tasks' . "\n";

	foreach my $task (@{$data_tasks{ul_li_rap_rask_li_span_class_name}}) {
		print 'Requesting /rw/rapid/symbols/search (' . $task . ')...';
		my(%data_pers) = http_request('post', '/rw/rapid/symbols/search', 'view=block&vartyp=any&blockurl=RAPID/' . $task . '&recursive=true&onlyused=true&skipshared=false&symtyp=per');
		print 'found ' . (defined $data_pers{ul_li_rap_symproppers_li_span_class_symburl} ? scalar(@{$data_pers{ul_li_rap_symproppers_li_span_class_symburl}}) : '0') . ' PERS program-data' . "\n";
		push(@resources, (defined $data_pers{ul_li_rap_symproppers_li_span_class_symburl} ? @{$data_pers{ul_li_rap_symproppers_li_span_class_symburl}} : ()));
	}

    open(my $fh, '>', $file_server_resources) or die 'Cannot write "' . $file_server_resources . '"' . "\n";
    print $fh $_ . "\n" for @resources;
    close $fh;

    print 'Saved ' . scalar(@resources) . ' resources to "' . $file_server_resources . '"' . "\n";
    exit 0;
}



# -------------------------
# Read listen list
# -------------------------

sub read_listen_resources {
    open(my $fh, '<', $file_listen_resources) or return ();
    my @res;
    while (<$fh>) {
        chomp;
        next unless $_;
        push(@res, $_);
    }
    close($fh);
    return @res;
}



# -------------------------
# WebSocket subscription
# -------------------------

sub start_subscription {
    print 'Reading "' . $file_listen_resources . '"...';
    my @resources = read_listen_resources();
        ShowHelp() unless @resources;
    print 'ok' . "\n";
    # Build request body
    my $subbody;
    my $i = 1;
    foreach (@resources) {
        print '  ' . $_ . "\n";
        $subbody .= '&' if ($i > 1);
        $subbody .= 'resources=' . $i;
        $subbody .= '&' . $i . '=' . $_;
		# Priority
		# 2=High; Events are sent immediately. Max 64.
		# 1=Medium; Events are sent within 200ms delay.
		# 0=Low; Events are sent within 5s.
		# The first 64 entries in ListenResources will be set to HIGH, remaining will be set to MEDIUM.
		$subbody .= '&' . $i . '-p=' . ($i <= 64 ? 2 : 1);
		#$subbody .= '&' . $i . '-p=1';
        $i++;
		# Max 1000 resources are allowed for subscriptions.
		if ($i > 1000) {
			print 'WARNING: More than 1000 resources added to "ListenResources.txt" . Only the first 1000 are used.' . "\n";
			last;
		}
    }

    # Send subscription request
    print 'Sending subscription request...';
    my %data_ws = http_request('post', '/subscription', $subbody);
		die 'Missing websocket url from controller request' unless (defined $data_ws{a_rel_self});
	my $ws_url = $data_ws{a_rel_self};
    print 'ok' . "\n";
	
    print 'Connecting to websocket (' . $ws_url . ')...';
	my $abb_cookies = getHttpCookies();
    my $client = AnyEvent::WebSocket::Client->new(
        ssl_no_verify => 1,
		http_headers => {
			'Cookie' => $abb_cookies,
		},
		subprotocol => 'rws_subscription'
    );
		
    $client->connect($ws_url)->cb(sub {
		
        our $connection = eval { shift->recv };
		
		if ($@) {
			# handle error
			warn $@;
			return;
		}
		
        print 'Connected to WebSocket' . "\n";
		ProcessSubscriptionInit();

        $connection->on(each_message => sub {
            my($connection, $message) = @_;
			ProcessSubscriptionMessage($connection, $message->body);
        });

        $connection->on(finish => sub {
			my($connection) = @_;
            printl('WebSocket disconnected' . "\n");
			exit 1;
        });
		
    });
    print 'ok' . "\n";

	# Enter mainloop and log any incoming messages
    print 'Listening...' . "\n";
    AnyEvent->condvar->recv;
}



sub getHttpCookies {
	# Build a request, it is never executed, but cookie_jar will allow us to extract abb cookies this way
    my $baseurl = $Config->{connection}->{https} ? 'https://' . $server_ip . ':' . $server_port : 'http://' . $server_ip . ':' . $server_port;
    my $req = HTTP::Request->new(GET => $baseurl . '/rw');
    $ua->cookie_jar->add_cookie_header($req);
    return $req->header('Cookie');  # undef if no cookies apply
}



sub ProcessSubscriptionInit {
	printl("\n" . '### New session' . "\n");
	printl(TimeStampTime() . ' Date: ' . TimeStampDate() . "\n");
	printl(TimeStampTime() . ' Server: ' . $Config->{connection}->{server_ip} . ':' . $Config->{connection}->{server_port} . "\n");
	my %data_robotid = http_request('get', '/ctrl/identity');
	printl(TimeStampTime() . ' ControllerId: ' . (defined $data_robotid{span_ctrl_id} ? $data_robotid{span_ctrl_id} : '<CtrlId>') . ' (' . (defined $data_robotid{span_ctrl_name} ? $data_robotid{span_ctrl_name} : '<CtrlName>') . ')' . "\n");
	my %data_robotware = http_request('get', '/rw/system');
	printl(TimeStampTime() . ' Robotware: ' . (defined $data_robotware{ul_li_class_sys_system_span_class_rwversionname} ? $data_robotware{ul_li_class_sys_system_span_class_rwversionname} : '<Robotware>') . ' (' . (defined $data_robotware{ul_li_class_sys_system_span_class_build} ? $data_robotware{ul_li_class_sys_system_span_class_build} : '<build>') . ')' . "\n");
}



sub ProcessSubscriptionMessage {
	my($connection, $message) = @_;
	
	# Parse XML
	my $dom = XML::LibXML->load_xml(string => $message);

	# XPath context with XHTML namespace
	my $xpc = XML::LibXML::XPathContext->new($dom);
	$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

	# Locate <div class="state", then try to find link to next page	
	my ($div_state) = $xpc->findnodes('//x:div[@class="state"]');
	
	# Parsing persdata loop, Locate <ul in <div class="state", and loop through all <li class="rap-symproppers-li tags
	my ($ul) = $xpc->findnodes('.//x:ul', $div_state);	
	for my $li ($xpc->findnodes('//x:li[@class="rap-value-ev"]')) {
		my ($a) = $xpc->findnodes('.//x:a[@rel="self"]', $li);
		my ($b) = $xpc->findnodes('.//x:span[@class="value"]', $li);
		next unless $a && $b;
		my $resource_name = $a->getAttribute('href');
		my $resource_value = $b->textContent;
		my $resource_shortname = '<shortname>';
		$resource_shortname = $1 if ($resource_name =~ /\/([\w_]+)\/data/);
		printl(TimeStampTime() . ' ' . ($arg_short_naming ? $resource_shortname : $resource_name) . '=' . $b->textContent . "\n");
	}

	for my $li ($xpc->findnodes('//x:li[@class="ios-signalstate-ev"]')) {
		my ($a) = $xpc->findnodes('.//x:a[@rel="self"]', $li);
		my ($b) = $xpc->findnodes('.//x:span[@class="lvalue"]', $li);
		next unless $a && $b;
		my $resource_name = $a->getAttribute('href');
		my $resource_value = $b->textContent;
		my $resource_shortname = '<shortname>';
		$resource_shortname = $1 if ($resource_name =~ /\/([\w_]+);state/);
		printl(TimeStampTime() . ' ' . ($arg_short_naming ? $resource_shortname : $resource_name) . '=' . $b->textContent . "\n");
	}
}



sub TimeStampTime {
	my ($sec, $usec) = gettimeofday();
	my @td = localtime($sec);
	my $ms = int($usec / 1000);
	return sprintf("%02d:%02d:%02d.%03d", $td[2], $td[1], $td[0], $ms);
}

sub TimeStampDate {
	my @td = localtime(time());
	return sprintf("%04d-%02d-%02d", $td[5] + 1900, $td[4] + 1, $td[3]);
}

sub printl {
	my($text) = @_;
	print $text;
	# Also print to file if argument exist
	if ($arg_file_log) {
		open(my $logfile, '>>' , $arg_file_log);
		print $logfile $text;
		close($logfile);
	}
}

sub ShowHelp {
	print <<EOM;

Usage:

DataLogger.pl --reset_config
	Create a new config file. Should work out-of-the-box when using management
	port on	robotcontroller.

DataLogger.pl --list_resources
	Connect to controller ask for all IO and Persdata resources available.
	Dump everything into ServerResources.txt .

DataLogger.pl [--short_naming] [--log=<file>]
	Start logging of selected resources. Select resources by copying lines from
	ServerResources.txt into ListenResources.txt . If this file is missing you
	get to read this again :)

EOM
	exit 1;
}



# -------------------------
# Main
# -------------------------

printl 'AbbDataLogger rev2026-02-09 - https://github.com/RobotSigmund' . "\n";
list_resources() if ($arg_list_resources);

start_subscription();

exit 0;

