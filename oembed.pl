use strict;
use vars qw($VERSION %IRSSI);
use Data::Dumper;
use POSIX;
use Time::HiRes qw/sleep/;
use JSON;
use LWP::UserAgent;

use Irssi;
$VERSION = '20141120';
%IRSSI = (
    authors     => 'Jim The Cactus',
    contact     => 'themanhimself@jimthecactus.com',
    name        => 'deviantart',
    description => 'shows key stats about DeviantArt links',
    license     => 'Public Domain',
    changed     => $VERSION,
);

sub process_message { 
	my ($server, $data, $nick, $address) = @_;
	# Get the context we're coming from
	my ($target, $text) = split(/ :/,$data,2);
	# If we're the target (privmsg), then pivot it back to the sender.
	if (lc($target) eq lc($server->{nick})) {
		$target = $nick;
	} 

	# Get the URL to look up for this link, if any.
	my $result = uri_parse($text);
	if ($result) {
		my $url=$result->{url};
		my $service=$result->{service};
		# if we found one, spawn a handler.
		process_url($server,$target,$url,$service);
	}
	# And continue processing
	Irssi::signal_continue(@_);
} 

sub event_action {
        my ($server, $text, $nick, $address, $target) = @_;
	# If we're the target (privmsg), then pivot it back to the sender.
        if (lc($target) eq lc($server->{nick})) {
                $target = $nick;
        }

        # Get the URL to look up for this link, if any.
        my $result = uri_parse($text);
        if ($result) {
		my $url=$result->{url};
		my $service=$result->{service};
		print "Got Service: $service URL: $url";
                # if we found one, spawn a handler.
                process_url($server,$target,$url,$service);
        }
        # And continue processing
        Irssi::signal_continue(@_);
}


sub uri_parse { 
    my ($url) = @_; 
    # Check for a post...
    if ($url =~  /(?:https?:\/\/)?((?:[0-9A-Z-]*\.)?(?:deviantart\.com|fav\.me|sta\.sh)\/[^\s]+)/ig) {
        return {url=>"http://backend.deviantart.com/oembed?url=http%3A%2F%2F$1",service=>"DeviantArt"};
    }
    if ($url =~  /(?:https?:\/\/)?((?:[0-9A-Z-]*\.)?(?:imgur\.com)\/[^\s]+)/ig) {
        return {url=>"http://api.imgur.com/oembed?url=http%3A%2F%2F$1",service=>"Imgur"};
    }
    if ($url =~  /(?:https?:\/\/)?((?:[0-9A-Z-]*\.)?(?:flickr\.com\/photos|flic.kr\/p)\/[^\s]+)/ig) {
        return {url=>"http://www.flickr.com/services/oembed?format=json&url=http%3A%2F%2F$1",service=>"Flickr"};
    }
    if ($url =~  /(?:https?:\/\/)?((?:instagram\.com\/p|instagr.am\/p)\/[^\s]+)/ig) {
        return {url=>"http://api.instagram.com/oembed?format=json&url=http%3A%2F%2F$1",service=>"Instagram"};
    }
    if ($url =~  /(?:https?:\/\/)?(soundcloud\.com\/[^\s]+)/ig) {
        return {url=>"https://soundcloud.com/oembed?format=json&url=http%3A%2F%2F$1",service=>"Soundcloud"};
    }
    return 0; 
} 

sub uri_get { 
	my ($url) = @_; 

	# If we were given a valid URL
	if ($url) {
		# Calculate our user agent
		my $ua = LWP::UserAgent->new(env_proxy=>1, keep_alive=>1, timeout=>5); 
		$ua->agent("irssi/$VERSION " . $ua->agent()); 

		# Build the GET request
		my $req = HTTP::Request->new('GET', $url); 
		# And get the result
		my $res = $ua->request($req);

		my $result_string = '';
		my $json = JSON->new->utf8;

		eval {
			# And if it's a non-error response...
			if ($res->is_success()) { 
				eval {
					# Parse the result
					my $json_data = $json->decode($res->content());
					if ($json_data->{title}) {
						my $title = $json_data->{title};
						print "I have a title.";
						if (length($title) > 80) {
							$title = substr($title,0,70);
							$result_string .= "\x1F" . $title . "\x0F (trimmed)";
						}
						else {
							$result_string .= "\x1F" . $title . "\x0F";
						}
					}
					if ($json_data->{author_name}) {
						$result_string .= " by " . $json_data->{author_name};
					}
					if (length($result_string) == 0) {
						$result_string = "No title or author.";
					}
					
					# And let the eval know we're good even if there wasn't any posts.
					return 1;
				} or do {
					# Otherwise set the response to an error result.
					$result_string = "~~~ERROR~~~ Request successful, parsing error";
				};
			} 
			else {
				eval {
					$result_string = "~~~ERROR~~~ " . $res->status_line();
				} or do {
					# And failing that just thow a blanket error.
					$result_string = "~~~ERROR~~~ Parsing error";
				};
			}
		}
		or do {
			# If something goes really wrong, throw a blanket error.
			$result_string = "~~~ERROR~~~ Request error";
		};

		# Clean up any stray EOLs, just in case.
		chomp $result_string;
		# and pass this back.
		return $result_string; 
	}
} 

# When we get data back from the pipe
sub show_result {
	my $args = shift;
	my ($read_handle, $input_tag_ref, $job, $service) = @$args;

	# Read the result
	my $line=<$read_handle>;
	close($read_handle);
	# Stop looking for data
	Irssi::input_remove($$input_tag_ref);
	# grab the parts of our result
	my ($server_tag,$target,$retval) = split("~~~SEP~~~",$line,3);
	# check that we have what we need
	if (!$server_tag || !$target || !$retval) {
		Irssi::print("Didn't receive usable data from child.");
		return;
	}

	# clean up any EOLs
	chomp $retval;	

	# Check if it's an error and print it instead
	if ($retval =~ /^~~~ERROR~~~/) {
		Irssi::print("oEmbed error for $service: $retval");
		return;
	}

	# Otherwise grab the server
	my $server = Irssi::server_find_tag($server_tag);
	if (!$server) {
		Irssi::print("Failed to find $server_tag in server tag list.");
		return;
	}
	# and write our result to the stream.
	$server->command("msg $target $service: $retval") if $retval;
}


sub process_url {
	my ($server, $target, $url,$service) = @_;
	my ($parent_read_handle, $child_write_handle);


	# Setup the interprocess communication pipe
	pipe($parent_read_handle, $child_write_handle);

	my $oldfh = select($child_write_handle);
	$| = 1;
	select $oldfh;

	# Split off a child process.
	my $pid = fork();
	if (not defined $pid) {
        	print("Can't fork: Aborting");
	        close($child_write_handle);
        	close($parent_read_handle);
	        return;
	}

	if ($pid > 0) { # this is the parent (Irssi)
		# Toss the unnecessary write handle.
		close ($child_write_handle);
		# mark that we're supposed to wait on our child.
		Irssi::pidwait_add($pid);
		my $job = $pid;
		my $tag;
		my @args = ($parent_read_handle, \$tag, $job, $service);
		#Spin up the output listener.
	        $tag = Irssi::input_add(fileno($parent_read_handle),
			Irssi::INPUT_READ,
			\&show_result,
			\@args);

	} else { # child
		# Ask the server for the information about the link
		my $description = uri_get($url);
		my $server_tag = $server->{tag};

		# Tell the parent what we found
		print $child_write_handle "$server_tag~~~SEP~~~$target~~~SEP~~~" . $description . "\n";
		# close our pipe
		close($child_write_handle);
		# and bail.
		POSIX::_exit(1);
	}
}


Irssi::signal_add_last('event privmsg', 'process_message'); 
Irssi::signal_add('message irc action', 'event_action');
