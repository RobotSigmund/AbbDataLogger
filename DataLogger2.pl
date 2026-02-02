#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
use Config::Tiny;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use LWP::UserAgent;
use HTTP::Cookies;
use JSON;
use HTML::TreeBuilder::XPath;
use URI::Escape;
use AnyEvent::WebSocket::Client;



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
my $listresources = '';
my $reset_config = '';
GetOptions(
    "listresources"   => \$listresources,
    "reset_config"   => \$reset_config,
    "log=s"           => \$file_log,
);



# -------------------------
# New default config file
# -------------------------

if ($reset_config) {
    my $Config_new = Config::Tiny->new({
        connection => { server_ip => '192.168.125.1', server_port => '80', https => '1', username => 'Default User', password => 'robotics' },
        files => { file_server_resources => 'ServerResources.txt', file_listen_resources => 'ListenResources.txt' }
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
$ua->default_header('Accept' => 'application/hal+json;v=2.0');

$ua->ssl_opts(
    SSL_verify_mode => SSL_VERIFY_NONE,
    verify_hostname => 0,
);

sub rws_get {
    my($path) = @_;
    my $baseurl = $Config->{connection}->{https} ? 'https://' . $server_ip . ':' . $server_port : 'http://' . $server_ip . ':' . $server_port;
    my $res = $ua->get($baseurl . $path);
        die 'LWP GET failed: ' . $baseurl . $path . "\n" . 'Status: ' . $res->status_line . "\n" . 'Headers:' . "\n" . $res->headers_as_string . "\n" . 'Body:' . "\n" . $res->decoded_content . "\n" unless $res->is_success;
    return decode_json($res->decoded_content);
}

sub rws_post {
    my($path, %formdata) = @_;
    my $baseurl = $Config->{connection}->{https} ? 'https://' . $server_ip . ':' . $server_port : 'http://' . $server_ip . ':' . $server_port;
    my $res = $ua->post($baseurl . $path, Content_Type => 'application/x-www-form-urlencoded;v=2.0', Accept => 'application/xhtml+xml;v=2.0', Content => \%formdata);
        die 'LWP POST failed: ' . $baseurl . $path . "\n" . 'Status: ' . $res->status_line . "\n" . 'Headers:' . "\n" . $res->headers_as_string . "\n" . 'Body:' . "\n" . $res->decoded_content . "\n" unless $res->is_success;
    return $res->decoded_content;
}

sub rws_sub {
    my($path, $formdata) = @_;
    my $baseurl = $Config->{connection}->{https} ? 'https://' . $server_ip . ':' . $server_port : 'http://' . $server_ip . ':' . $server_port;
    my $req = HTTP::Request->new(POST => $baseurl . $path);
    $req->header('Accept' => 'application/xhtml+xml;v=2.0');
    $req->header('Content-type' => 'application/x-www-form-urlencoded;v=2.0');
    $req->header('Content-length' => length($formdata));
    $req->content($formdata);
    my $res = $ua->request($req);
        die 'LWP POST failed: ' . $baseurl . $path . "\n" . 'Request:' . "\n" . $req->as_string . "\n" . 'Status: ' . $res->status_line . "\n" . 'Headers:' . "\n" . $res->headers_as_string . "\n" . 'Body:' . "\n" . $res->decoded_content . "\n" unless $res->is_success;
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
        my $io = rws_get('/rw/iosystem/signals?start=' . $start . '&limit=' . $limit);
        foreach my $sig (@{$io->{_embedded}->{resources}}) {
            push(@resources, '/rw/iosystem/' . $sig->{_links}->{self}->{href} . ';state');
        }
        # Check for 'next' page
        if (exists $io->{_links}->{next} && $io->{_links}->{next}->{href}) {
            # Parse next start index from href
            $start = $1 if ($io->{_links}->{next}->{href} =~ /start=(\d+)/);
            $limit = $1 if ($io->{_links}->{next}->{href} =~ /limit=(\d+)/);
        } else {
            last;   # no more pages
        }
    }

    # RAPID data
    foreach my $task (get_tasks()) {
        my $start = 0;
        my $limit = 100;
        while (1) {
            my $data_xml = rws_post('/rw/rapid/symbols/search?start=' . $start . '&limit=' . $limit, ( view => 'block', vartyp => 'any', blockurl => 'RAPID/' . $task, recursive => 'true', onlyused => 'true', skipshared => 'false', symtyp => 'per' ) );
            push(@resources, extract_symburls($data_xml));

            my $nextpage = extract_next_href($data_xml);
            if ($nextpage) {
                # Parse next start index from href
                $start = $1 if ($nextpage =~ /start=(\d+)/);
                $limit = $1 if ($nextpage =~ /limit=(\d+)/);
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

sub get_tasks {
    my $res = rws_get('/rw/rapid/tasks');

    return map { $_->{name} } grep { ($_->{_type} // '') eq 'rap-task-li' } @{ $res->{_embedded}->{resources} // [] };
}

sub extract_symburls {
    my($xhtml) = @_;

    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse($xhtml);
    $tree->eof;

    my @symbols;

    for my $node ($tree->findnodes('//span[@class="symburl"]')) {
        my $text = $node->as_text;
        $text =~ s/^\s+|\s+$//g;   # trim
        push(@symbols, '/rw/rapid/symbol/' . $text . ';value') if length $text;
    }

    $tree->delete;
    return @symbols;
}

sub extract_next_href {
    my ($xhtml) = @_;

    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse($xhtml);
    $tree->eof;

    my ($attr) = $tree->findnodes('//a[@rel="next"]/@href');

    $tree->delete;

    return $attr ? $attr->getValue : undef;
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
        $subbody .= '&' . $count . '=' . uri_escape($_);
        $subbody .= '&' . $count . '-p=' . ($count <= 64 ? 2 : 1);
        $count++;
    }

    # Send subscription request
    print 'Sending subscription request...';
    my $sub_res = rws_sub('/subscription', $subbody);
    print 'ok' . "\n";
    my $ws_url = extract_ws_href($sub_res);

    print 'Connecting to websocket (' . $ws_url . ')...';
    my $client = AnyEvent::WebSocket::Client->new(
        ssl_no_verify => 1
    );
    my $cv = AnyEvent->condvar;

    $client->connect($ws_url)->cb(sub {
        my $conn = eval { shift->recv };
        die 'WebSocket connect failed: $@' if $@;

        print 'Connected to WebSocket' . "\n";

        $conn->on(each_message => sub {
            my ($c, $msg) = @_;
            print 'UPDATE: ' . $msg->body;
        });

        $conn->on(finish => sub {
            print 'WebSocket disconnected';
            $cv->send;
        });
    });
    print 'ok' . "\n";

    print 'Listening...' . "\n";
    $cv->recv;
}

sub extract_ws_href {
    my ($xhtml) = @_;

    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse($xhtml);
    $tree->eof;

    my ($attr) = $tree->findnodes('//a[@rel="self"]/@href');

    $tree->delete;

    return $attr ? $attr->getValue : undef;
}



# -------------------------
# Main
# -------------------------

list_resources() if ($listresources);

start_subscription();

exit 0;

