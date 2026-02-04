#!/usr/bin/perl

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

sub rws_get {
    my($path) = @_;
    my $baseurl = $Config->{connection}->{https} ? 'https://' . $server_ip . ':' . $server_port : 'http://' . $server_ip . ':' . $server_port;
	my $req = HTTP::Request->new(
		GET => $baseurl . $path,
		[
			'Accept' => 'application/xhtml+xml;v=2.0',
			'Authorization' => 'Basic ' . encode_base64($Config->{connection}->{username} . ':' . $Config->{connection}->{password} . ''),
		],
	);
	$ua->cookie_jar->add_cookie_header($req);
	my $res = $ua->request($req);
		
	unless ($res->is_success) {
		die 'GET request failed: ' . $baseurl . $path . "\n"
			. "Status: " . $res->status_line . "\n"
			. "Request:\n" . $req->as_string . "\n"
			. "Response headers:\n" . $res->headers_as_string . "\n"
			. "Response body:\n" . $res->decoded_content . "\n";
	}
	
    return $res->decoded_content;
}

sub rws_post {
    my($path, $formdata) = @_;
    my $baseurl = $Config->{connection}->{https} ? 'https://' . $server_ip . ':' . $server_port : 'http://' . $server_ip . ':' . $server_port;
	
	my $req = HTTP::Request->new(
		POST => $baseurl . $path,
		[
			'Accept' => 'application/xhtml+xml;v=2.0',
			'Content-type' => 'application/x-www-form-urlencoded;v=2.0',
			'Content-length' => length($formdata),
			'Authorization' => 'Basic ' . encode_base64($Config->{connection}->{username} . ':' . $Config->{connection}->{password} . ''),
		],
		$formdata
	);
	$ua->cookie_jar->add_cookie_header($req);
	my $res = $ua->request($req);

	unless ($res->is_success) {
		die 'POST request failed: ' . $baseurl . $path . "\n"
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

    # IO signals
    my $start = 0;
    my $limit = 100;
    while (1) {
		print 'Requesting /rw/iosystem/signals?start=' . $start . '&limit=' . $limit . '...';
		my($next, $ref_signalurls) = xhtml_iolist_parse(rws_get('/rw/iosystem/signals?start=' . $start . '&limit=' . $limit));
		print 'found ' . scalar(@{$ref_signalurls}) . ' signals' . "\n";
        push(@resources, @{$ref_signalurls});
		
		last unless $next;
		# Parse next start index from href
		$start = $1 if ($next =~ /start=(\d+)/);
		$limit = $1 if ($next =~ /limit=(\d+)/);
    }

    # RAPID data
    my $xhtml_tasks = rws_get('/rw/rapid/tasks');
    foreach my $task (xhtml_tasks_parse($xhtml_tasks)) {
        my $start = 0;
        my $limit = 100;
        while (1) {
			print 'Requesting /rw/rapid/symbols/search?start=' . $start . '&limit=' . $limit . ', blockurl=RAPID/' . $task . '...';
			my($next, $ref_persdataurls) = xhtml_persdata_parse(rws_post('/rw/rapid/symbols/search?start=' . $start . '&limit=' . $limit, 'view=block&vartyp=any&blockurl=RAPID/' . $task . '&recursive=true&onlyused=true&skipshared=false&symtyp=per'));
			print 'found ' . scalar(@{$ref_persdataurls}) . ' PERS program-data' . "\n";
            push(@resources, @{$ref_persdataurls});

			last unless $next;
			# Parse next start index from href
			$start = $1 if ($next =~ /start=(\d+)/);
			$limit = $1 if ($next =~ /limit=(\d+)/);
        }
    }

    open(my $fh, '>', $file_server_resources) or die 'Cannot write "' . $file_server_resources . '"' . "\n";
    print $fh $_ . "\n" for @resources;
    close $fh;

    print 'Saved ' . scalar(@resources) . ' resources to "' . $file_server_resources . '"' . "\n";
    exit 0;
}

sub xhtml_tasks_parse {
	my($xhtml) = @_;

	my @list;
	
	# Parse XML
	my $dom = XML::LibXML->load_xml(string => $xhtml);

	# XPath context with XHTML namespace
	my $xpc = XML::LibXML::XPathContext->new($dom);
	$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

	# Locate <div class="state", then try to find link to next page	
	my ($div_state) = $xpc->findnodes('//x:div[@class="state"]');

	# Parsing IO loop, Locate <ul in <div class="state", and loop through all <li class="ios-signal-li tags
	my ($ul) = $xpc->findnodes('.//x:ul', $div_state);	
	for my $li ($xpc->findnodes('.//x:li[@class="rap-task-li"]', $ul)) {
		# Find the <a href="foobar" rel="self"
		my ($a) = $xpc->findnodes('.//x:span[@class="name"]', $li);
		next unless $a;
		# Add foobar to resultarray
		push(@list, $a->textContent);
	}
	
	# If we find a next-page-href, we add it, then the results.
	return(@list);
}

sub xhtml_iolist_parse {
	my($xhtml) = @_;
	
	my @list;
	
	# Parse XML
	my $dom = XML::LibXML->load_xml(string => $xhtml);

	# XPath context with XHTML namespace
	my $xpc = XML::LibXML::XPathContext->new($dom);
	$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

	# Locate <div class="state", then try to find link to next page	
	my ($div_state) = $xpc->findnodes('//x:div[@class="state"]');
	my ($a_next) = $xpc->findnodes('.//x:a[@rel="next"]', $div_state);

	# Parsing IO loop, Locate <ul in <div class="state", and loop through all <li class="ios-signal-li tags
	my ($ul) = $xpc->findnodes('.//x:ul', $div_state);	
	for my $li ($xpc->findnodes('.//x:li[@class="ios-signal-li"]', $ul)) {
		# Find the <a href="foobar" rel="self"
		my ($a) = $xpc->findnodes('.//x:a[@rel="self"]', $li);
		next unless $a;
		# Add foobar to resultarray
		push(@list, '/rw/iosystem/' . $a->getAttribute('href') . ';state');
	}
	
	# If we find a next-page-href, we add it, then the results.
	return($a_next ? $a_next->getAttribute('href') : undef, \@list);
}

sub xhtml_persdata_parse {
    my($xhtml) = @_;

	my @list;
	
	# Parse XML
	my $dom = XML::LibXML->load_xml(string => $xhtml);

	# XPath context with XHTML namespace
	my $xpc = XML::LibXML::XPathContext->new($dom);
	$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

	# Locate <div class="state", then try to find link to next page	
	my ($div_state) = $xpc->findnodes('//x:div[@class="state"]');
	my ($a_next) = $xpc->findnodes('.//x:a[@rel="next"]', $div_state);

	# Parsing persdata loop, Locate <ul in <div class="state", and loop through all <li class="rap-symproppers-li tags
	my ($ul) = $xpc->findnodes('.//x:ul', $div_state);	
	for my $li ($xpc->findnodes('//x:li[@class="rap-symproppers-li"]')) {
		my ($a) = $xpc->findnodes('.//x:span[@class="symburl"]', $li);
		next unless $a;
		push(@list, '/rw/rapid/symbol/' . $a->textContent . '/data;value');
	}
	
	return($a_next ? $a_next->getAttribute('href') : undef, \@list);
}

sub xhtml_wssurl_parse {
    my($xhtml) = @_;
	
	# Parse XML
	my $dom = XML::LibXML->load_xml(string => $xhtml);

	# XPath context with XHTML namespace
	my $xpc = XML::LibXML::XPathContext->new($dom);
	$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

	# Locate <div class="state", then try to find link to self page	which is subscription websocket url
	my ($div_state) = $xpc->findnodes('//x:div[@class="state"]');
	my ($a_next) = $xpc->findnodes('.//x:a[@rel="self"]', $div_state);
	
	return($a_next ? $a_next->getAttribute('href') : undef);
}

sub xhtml_robotid_parse {
    my($xhtml) = @_;
	
	# Parse XML
	my $dom = XML::LibXML->load_xml(string => $xhtml);

	# XPath context with XHTML namespace
	my $xpc = XML::LibXML::XPathContext->new($dom);
	$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

	# Locate <div class="state", then try to find link to self page	which is subscription websocket url
	my ($div_state) = $xpc->findnodes('//x:div[@class="state"]');
	my ($span_ctrl_name) = $xpc->findnodes('.//x:span[@class="ctrl-name"]', $div_state);
	my ($span_ctrl_id) = $xpc->findnodes('.//x:span[@class="ctrl-id"]', $div_state);
	
	return(($span_ctrl_id ? $span_ctrl_id->textContent : '<ctrl-id>') . ' (' . ($span_ctrl_name ? $span_ctrl_name->textContent : '<ctrl-name>') . ')');
}

sub xhtml_robotware_parse {
    my($xhtml) = @_;
	
	# Parse XML
	my $dom = XML::LibXML->load_xml(string => $xhtml);

	# XPath context with XHTML namespace
	my $xpc = XML::LibXML::XPathContext->new($dom);
	$xpc->registerNs(x => 'http://www.w3.org/1999/xhtml');

	# Locate <div class="state", then try to find link to self page	which is subscription websocket url
	my ($div_state) = $xpc->findnodes('//x:div[@class="state"]');
	my ($ul) = $xpc->findnodes('.//x:ul', $div_state);
	my ($li) = $xpc->findnodes('.//x:li[@class="sys-system"]', $ul);
	my ($span_rwversionname) = $xpc->findnodes('.//x:span[@class="rwversionname"]', $li);
	my ($span_build) = $xpc->findnodes('.//x:span[@class="build"]', $li);
	
	return(($span_rwversionname ? $span_rwversionname->textContent : '<rwversionname>') . ' build ' . ($span_build ? $span_build->textContent : '<build>'));
}



# -------------------------
# Read listen list
# -------------------------

sub read_listen_resources {
    open(my $fh, '<', $file_listen_resources) or die 'Cannot read "' . $file_listen_resources . '"' . "\n";
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
        die 'No resources in "' . $file_listen_resources . '"' . "\n" unless @resources;
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
    my $xhtml_subscription = rws_post('/subscription', $subbody);
    print 'ok' . "\n";
    my $ws_url = xhtml_wssurl_parse($xhtml_subscription);
	
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
	my $xhtml_robotid = rws_get('/ctrl/identity');
	my $robotid = xhtml_robotid_parse($xhtml_robotid);
	printl(TimeStampTime() . ' ControllerId: ' . $robotid . "\n");
	my $xhtml_robotware = rws_get('/rw/system');
	my $robotware = xhtml_robotware_parse($xhtml_robotware);
	printl(TimeStampTime() . ' Robotware: ' . $robotware . "\n");
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



	# Example websocket subscription update for Pers-data:
	# <?xml version="1.0" encoding="utf-8"?>
	# <html xmlns="http://www.w3.org/1999/xhtml"> 
	# <head>
	#   <base href="https://192.168.125.1:443/"/> 
	# </head>
	# <body> 
	#   <div class="state">
	#     <a href="subscription/56" rel="group"></a>
	#     <ul> 
	#       <li class="rap-value-ev" title="value">
	#         <a href="/rw/rapid/symbol/RAPID/T_PLC/R2StraighteningStnMod/nR2StraightenerPlcRsp/data" rel="self"/> 
	#         <span class="value">0</span>
	#       </li>  
	#     </ul> 
	#   </div>
	# </body>
	# </html>
	
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
	
	
	
	# Example websocket subscription update for IO:
	# <?xml version="1.0" encoding="utf-8"?>
	# <html xmlns="http://www.w3.org/1999/xhtml">
	# <head>
	#   <base href="https://192.168.125.1:443/"/>
	# </head>
	# <body>
	#   <div class="state">
	#     <a href="subscription/53" rel="group"></a>
	#     <ul>
	#       <li class="ios-signalstate-ev" title="PROFINET/CPX_R2_Fixture/doR2StraightenerCylOut">
	#         <a href="/rw/iosystem/signals/PROFINET/CPX_R2_Fixture/doR2StraightenerCylOut;state" rel="self"/>
	#         <span class="lvalue">0</span>
	#         <span class="lstate">not simulated</span>
	#         <span class="quality">good</span>
	#         <span class="time">276117</span>
	#       </li>
	#     </ul>
	#   </div>
	# </body>
	# </html>

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


# -------------------------
# Main
# -------------------------

list_resources() if ($arg_list_resources);

start_subscription();

exit 0;

