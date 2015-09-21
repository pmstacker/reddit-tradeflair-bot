#!/usr/bin/perl -wT

use Reddit::Client;
use JSON;
use Data::Dumper;

# Authentication settings
my $client_id		= "";
my $secret		= "";
my $username		= "";
my $password		= "";
my $stateFile		= "pmsbot.state";

my $confirmedMessage	= "Confirmed: 1 point awarded to /u/%s and /u/%s.";
my $confirmedRE		= qr/^Confirmed:/;

my $blackListedTraders	= qr/^(ShinyBot|AutoModerator)$/;
my $botNames = qr/^(ShinyBot|PMsBot)$/;

# Read from the statefile
sub readState() {
	if(-r $stateFile) {
		open(SFH, $stateFile) || die "Unable to read statefile";
		my $js;
		do {
			local $/ = undef;
			$js = <SFH>;
			close(SFH);
		};
		$state = decode_json($js);
		$config = $state->{'config'};
		delete $state->{'config'};
	} else {
		die "No statefile";
	}
}

# Write to the statefile (temp, then rename)
sub writeState() {
	if(-e $stateFile . ".tmp") {
		unlink($stateFile . ".tmp");
	}
	if(-w ".") {
		open(SFH, "+>" . $stateFile . ".tmp") || die "Unable to read statefile";
		my $js = $state;
		$js->{'config'} = $config;
		do {
			local $/ = undef;
			print SFH encode_json($js);
			close(SFH);
			rename($stateFile . ".tmp", $stateFile);
		};
	} else {
		die "Unable to save state";
	}
}

readState();

# Create a Reddit::Client object and authorize in one step
my $reddit = new Reddit::Client(
	user_agent	=> 'PMsBot v1.0 by /u/pmstacker',
	client_id	=> $config->{'client_id'},
	secret		=> $config->{'secret'},
	username	=> $config->{'username'},
	password	=> $config->{'password'},
);

# Fetch new comments based on the "lastCommentChecked" from the state file
sub fetchNewComments() {
	my $data;

	while(!$data) {
		$data = $reddit->json_request(
			"GET",
			sprintf("/r/%s/comments", $config->{'commentSub'}),
			{
				"before" => $state->{'lastCommentChecked'},
				"limit" => $config->{'commentLimit'},
				"sort" => "old"
			}
		) or sleep(5);
	}
	#print Dumper($data) . "\n\n";
	return $data->{'data'}->{'children'};
}

# Fetch child comments for a particular comment
sub fetchChildCommentsFor($$) {
	my $article = shift;
	my $parentComment = shift;

	my $data;

	while(!$data) {
		$data = $reddit->json_request(
			"GET",
			sprintf("/r/%s/comments/%s/_/%s", $config->{'commentSub'}, $article, $parentComment),
			{
				"context" => 0,
				"depth" => 2,
				"sort" => "old"
			}
		) or sleep(5);
	}
	while($data) {
		my $t = shift(@{$data});
		next unless($t->{'data'}->{'children'}->[0]->{'kind'} eq "t1");
		return $t->{'data'}->{'children'}->[0]->{'data'}->{'replies'}->{'data'}->{'children'};
	}
	return undef;
}

# Fetch an object; allows us to get detailed info about a particular comment
sub fetchObject($) {
	my $targetObject = shift;
	my $data;

	while(!$data) {
		$data = $reddit->json_request(
			"GET",
			sprintf("/api/info"),
			{
				"id" => $targetObject,
			}
		) or sleep(5);
	}
	#print "Object:\n" . encode_json($data) . "\n\n";
	#print Dumper($data) . "\n\n";
	return $data->{'data'}->{'children'}->[0]->{'data'};
}

# Post new flairs for the two users
sub updateFlairs($$$$) {
	my $opName = shift;
	my $opFlair = shift;
	my $spName = shift;
	my $spFlair = shift;

	my $csvText = sprintf("%s,%s,%s\n%s,%s,%s\n", $opName, $opFlair, $config->{'cssClass'}, $spName, $spFlair, $config->{'cssClass'});

	my $data;

	while(!$data) {
		$data = $reddit->json_request(
			"POST",
			sprintf("/api/flaircsv"),
			{},
			{ "r" => $config->{'commentSub'}, "flair_csv" => $csvText },
		) or sleep(5);
	}
	return $data;
}

# Post a comment
sub postComment($$) {
	my $parent = shift;
	my $comment = shift;

	my $data;

	while(!$data) {
		$data = $reddit->json_request(
			"POST",
			sprintf("/api/comment"),
			{},
			{ "thing_id" => $parent, "text" => $comment },
		) or sleep(5);
	}
	return $data;
}

while(1) {
	my $comments = fetchNewComments();
	COMMENT: foreach my $_comment (@$comments) {
		my $opName;
		my $opFlair;
		my $traderName;
		my $traderFlair;

		$comment = $_comment->{'data'};
		$opFlair = ($comment->{'author_flair_text'})?$comment->{'author_flair_text'}:0;

		printf("%s [%s] said: %s\n", $comment->{'author'}, $opFlair, $comment->{'body'});

		# The user said trade verified!
		if($comment->{'body'} =~ /Trade verified\!/i) {

			# OP posted it
			if($comment->{'author'} eq $comment->{'link_author'}) {
				$opName = $comment->{'link_author'};

				if($comment->{'parent_id'}) {
					my $parentComment = fetchObject($comment->{'parent_id'});
					unless($parentComment) {
						printf("Bad comment? Skipping...\n");
						next;
					}

					# Parent author and OP are the same
					if($parentComment->{'author'} eq $comment->{'author'}) {
						printf("Parent author and OP are same. Scam? (%s == %s)\n", $parentComment->{'author'}, $comment->{'author'});
					} else {
						$traderName = $parentComment->{'author'};
						$traderFlair = ($parentComment->{'author_flair_text'})?$parentComment->{'author_flair_text'}:0;
					}
				} else {
					# No parent, probable scam
					printf("Couldn\'t find a parent... trying to scam?\n");
				}
				if($opName and $traderName) {
					if($traderName =~ /$blackListedTraders/) {
						printf("Got a match, but trader (%s) is blacklisted, skipping!\n", $traderName);
						next;
					}
					if($opName =~ /$blackListedTraders/) {
						printf("Got a match, but OP (%s) is blacklisted, skipping!\n", $opName);
						next;
					}
					if($opName eq $traderName) {
						printf("OP == trader (%s == %s), skipping!\n", $opName, $traderName);
						next;
					}
					my $linkShort = $comment->{'link_id'};
					$linkShort =~ s/^t3_//;
					my $childComments = fetchChildCommentsFor($linkShort, $comment->{'id'});
					foreach my $_childComment (@$childComments) {
						my $childComment = $_childComment->{'data'};
						printf("%s [child] said: %s\n", $childComment->{'author'}, $childComment->{'body'});
						if($childComment->{'author'} =~ /$botNames/) {
							print "^- IS BOT\n";
							if($childComment->{'body'} =~ /$confirmedRE/) {
								printf("Already confirmed this one... moving on\n");
								next COMMENT;
							}
						}
					}
					$opFlair = ($opFlair=~/^[0-9]+/)?$opFlair+1:$opFlair;
					$traderFlair = ($traderFlair=~/^[0-9]+/)?$traderFlair+1:$traderFlair;
					updateFlairs($opName, $opFlair, $traderName, $traderFlair);
					printf("%s = %s\n%s = %s\n\n", $opName, $opFlair, $traderName, $traderFlair);
					my $message = sprintf($confirmedMessage, $opName, $traderName);
					print $message . "\n";
					postComment($comment->{'name'}, $message);
				}
			}
			
		}
		sleep(1);
		$state->{'lastCommentChecked'} = $comment->{'name'};
		writeState();
	}
	sleep(10);
}
