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

my $file_log = '';
my $list_resources = '';
my $reset_config = '';
GetOptions(
    "list_resources"   => \$list_resources,
    "reset_config"   => \$reset_config,
    "log=s"           => \$file_log,
);



# -------------------------
# New default config file
# -------------------------

if ($reset_config) {
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

my $ua = LWP::UserAgent->new( timeout => 10, cookie_jar => HTTP::Cookies->new() );
$ua->credentials($Config->{connection}->{server_ip} . ':' . $Config->{connection}->{server_port}, 'validusers@robapi.abb', $Config->{connection}->{username}, $Config->{connection}->{password});

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
	
	open(my $file, '>>http.log') or die 'Cant open logfile for writing';
		print $file 'NEW REQUEST:' . "\n"
			. "Request:\n" . $req->as_string . "\n"
			. "Status: " . $res->status_line . "\n"
			. "Response headers:\n" . $res->headers_as_string . "\n"
			. "Response body:\n" . $res->decoded_content . "\n";
	close($file);
	
	unless ($res->is_success) {
		die 'LWP GET failed: ' . $baseurl . $path . "\n"
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

	open(my $file, '>>http.log') or die 'Cant open logfile for writing';
		print $file 'NEW REQUEST:' . "\n"
			. "Request:\n" . $req->as_string . "\n"
			. "Status: " . $res->status_line . "\n"
			. "Response headers:\n" . $res->headers_as_string . "\n"
			. "Response body:\n" . $res->decoded_content . "\n";
	close($file);

	unless ($res->is_success) {
		die 'LWP POST SUB failed: ' . $baseurl . $path . "\n"
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
        # Check for 'next' page
        if ($next) {
            # Parse next start index from href
            $start = $1 if ($next =~ /start=(\d+)/);
            $limit = $1 if ($next =~ /limit=(\d+)/);
        } else {
            last;   # no more pages
        }
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

            if ($next) {
                # Parse next start index from href
                $start = $1 if ($next =~ /start=(\d+)/);
                $limit = $1 if ($next =~ /limit=(\d+)/);
            } else {
                last;   # no more pages
            }
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
		push(@list, $a->textContent . '/data;value');
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
    my $count = 1;
    foreach (@resources) {
        print '  ' . $_ . "\n";
        $subbody .= '&' if ($count > 1);
        $subbody .= 'resources=' . $count;
        $subbody .= '&' . $count . '=' . $_;
        $subbody .= '&' . $count . '-p=' . ($count <= 64 ? 1 : 0);
        $count++;
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

        $connection->on(each_message => sub {
            my($connection, $message) = @_;
			ProcessSubscriptionMessage($connection, $message->body);
        });

        $connection->on(finish => sub {
			my($connection) = @_;
            print 'WebSocket disconnected';
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



#

sub ProcessSubscriptionMessage {
	my($connection, $message) = @_;
	
	#print $message . "\n\n";
	
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
		print FormatTime(time()) . ' ' . $a->getAttribute('href') . '=' . $b->textContent . "\n";
		if ($file_log) {
			open(my $logfile, '>>' , $file_log);
			print $logfile FormatTime(time()) . ' ' . $a->getAttribute('href') . '=' . $b->textContent . "\n";
			close($logfile);
		}
	}
	for my $li ($xpc->findnodes('//x:li[@class="ios-signalstate-ev"]')) {
		my ($a) = $xpc->findnodes('.//x:a[@rel="self"]', $li);
		my ($b) = $xpc->findnodes('.//x:span[@class="lvalue"]', $li);
		next unless $a && $b;
		print FormatTime(time()) . ' ' . $a->getAttribute('href') . '=' . $b->textContent . "\n";
		if ($file_log) {
			open(my $logfile, '>>' , $file_log);
			print $logfile FormatTime(time()) . ' ' . $a->getAttribute('href') . '=' . $b->textContent . "\n";
			close($logfile);
		}
	}
}

sub FormatTime {
	my($stime) = @_;
	
	my(@td) = localtime($stime);
	return sprintf("%04d-%02d-%02d %02d:%02d:%02d", $td[5] + 1900, $td[4] + 1, $td[3], $td[2], $td[1], $td[0]);
}



# -------------------------
# Main
# -------------------------

list_resources() if ($list_resources);

start_subscription();

exit 0;

