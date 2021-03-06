#!/usr/bin/perl -s
$| = 1;
use LWP::UserAgent;
use Net::Twitter;
use Pithub;
use Data::Dumper;

use strict;
use wordlist qw{fix_text check_common};
use errorcheck qw{check_php fix_php check_py fix_py check_go fix_go check_cpp fix_cpp check_shell fix_shell};
use blacklist qw{ ok_to_update };


my $p = Pithub->new;

my $c = 0;
print "using ck $consumer_key / secret $consumer_secret\n";
my $nt = Net::Twitter->new(
    traits   => [qw/OAuth API::REST/],
    consumer_key        => $consumer_key,
    consumer_secret     => $consumer_secret,
);
$nt->access_token();
$nt->access_token_secret();

my $ua = new LWP::UserAgent;
print "Hello!\n";
print "Connecting to github!\n";
print "Reading input\n";
while (my $l = <>) {
    if ($l =~ /github\.com\/(.*?)\s*$/) {
        print "Checking $1\n";
        my $url = "https://www.github.com/".$1;
        $url =~ s/raw\/.*?\//raw\/master\//;
        handle_url($url);
    } else {
        print "fuck $l\n";
    }
}

sub handle_url {
    my $url = shift @_;
    print "looking at $url\n";
    if ($url =~ /http.*\/(.*?)\/(.*?)\/(raw\/|)(master|development|\w+)\/(.*)/) {
        my $ruser = $1;
        my $repo = $2;
        my $file = $4;
        print "u:".$ruser."\n";
        print "r:".$repo."\n";
        print "f:".$file."\n";
        my $result = $p->repos->get( user => $ruser , repo => $repo);
        my $traverse = 0;
        #Do we need to go up a level?
        while ($traverse < 10 && $result->content->{source}) {
            my $above = $result->content->{source}->{url};
            print "Yup, source exists was pulled from $above\n";
            if ($above =~ /repos\/(.*?)\/(.*)$/) {
                $ruser = $1;
                $repo = $2;
            }
            $result = $p->repos->get( user => $ruser , repo => $repo);
            $traverse++;
        }
        if (!ok_to_update($ruser)) {
            #Fuck no love
            return 0;
        }
        #Ok dokey lets try and fork this business
        print "trying to fork!\n";
        my $f = Pithub::Repos::Forks->new(token => $token);
        my $result = $f->create( user => $ruser, repo => $repo);
        my $clone_url = $result->content->{ssh_url};
        my $upstream_url = $result->content->{parent}->{ssh_url};
        my $master_branch = $result->content->{parent}->{master_branch} || "master";
        print "using master branch: $master_branch\n";
        #Oh hey lets merge the latest business to eh (just in case we have an old fork)
        `rm -rf foo && mkdir -p foo && cd foo && git clone "$clone_url" && cd * && git remote add upstream "$upstream_url" && git fetch upstream && git merge upstream/$master_branch && git push`;
        print "Did the sexy bit!\n";
        #Get the files
        my @all_files;
        open (my $files,"find ./foo/|");
        while (my $file = <$files>) {
            chomp ($file);
            push @all_files, $file;
        }
        close ($files);
        #Now we iterate through each of the processors so the git commit messages are grouped logically
        print "handling the files\n";
        my @changes = handle_files(@all_files);
        #Did we change anything?
        if ($#changes > 0) {
            #Yes!
            my $pull_msg = generate_pull_msg(@changes);
            my $twitter_msg = generate_twitter_msg(@changes);
            #Make pull
            my $pu = Pithub::PullRequests->new(user => $user ,token => $token);
            my $result = $pu->create(user => $user,
                                     repo => $repo,
                                     data => {
                                         title => "Pull request to a fix things",
                                         base => $master_branch,
                                         head => $master_branch});
            print "Dump".Dumper($result->content);
            exit();
            #Post to twitter
            $twitter_msg =~ s/\[LINK\]$/$link/;
        }
    }
}
sub generate_pull_msg {
    my @msgs = @_;
    my $msg_txt = join(' ',@msgs);
    my $pull_msg = "Fix ".$msg_txt." these changes are automagically generated by https://github.com/holdenk/holdensmagicalunicorn";
    return $pull_msg;
}
sub generate_twitter_msg {
    my ($pname,$link,@msgs) = @_;
    my $msgs_txt = join(' ',@msgs);
    my $message = "Fixing: ".$msgs_txt." in ".$pname." see pull request [LINK]";
    if (length($message) > 120) {
        $message =  "Fixing: ".$msgs_txt." in ".$pname." see [LINK]";
    }
    if (length($message) > 120) {
        $message = "Fixing ".$msgs_txt." in ".$pname." see [LINK]";
    }
    if (length($message) > 120) {
        $message = "Update to ".$pname." see pull request [LINK]";
    }
    return $message;
}
sub handle_files {
    print "handle_files called\n";
    my @files = @_;
    my @handlers = (handle_group("Fixing typos in README",qr/\/README(\.txt|\.rtf|\.md|\.m\w+)$/,\&check_common,\&fix_text),
                    handle_group("Fixing old PHP calls",qr/\.php$/,\&check_php,\&fix_php),
                    handle_group("Updating shell scripts",qr/\/\w(\.sh|\.bash|)$/,\&check_shell,\&fix_shell),
                    handle_group("Fixing deprecated django",qr/\.py$/,\&check_py,\&fix_py),
                    handle_group_cmd("Fixing go formatting",qr/\.go$/,\&check_go,\&fix_go));
    my @handler_names = ("typos","deprecated php","portable shell","deprecated django","go fix");
    print "have ".$#files." and ".$#handlers." to use\n";
    my $i = 0;
    my $short_msg = "Fix ";
    my @changes = ();
    while ($i < $#handlers+1) {
        print "running $i\n";
        print "Running handler $i / ".$handler_names[$i]."\n";
        my $r = $handlers[$i](@files);
        if ($r) {
            push @changes, $handler_names[$i];
        }
        $i++;
    }
    return @changes;
}
sub handle_group {
    my $git_message = shift @_;
    my $gate_regex = shift @_;
    my $gate_function = shift @_;
    my $fix_function = shift @_;
    return sub {
        my $changes = 0;
        my @files = @_;
        foreach my $file (@files) {
            if ($file !~ /\/\.git\// && $file =~ $gate_regex) {        
                open (my $in, "<", "$file") or die "Unable to open $file";
                my $t = do { local $/ = <$in> };
                close($in);
                #Is there a spelling mistake?
                if ($gate_function->($t)) {
                    open (my $out, ">", "$file") or die "Unable to open $file";
                    print $out $fix_function->($t);
                    close ($out);
                }                
            }
        }
        #Determine if we have made any difference
        `cd foo/*;git diff --exit-code`;
        if ($? != 0) {
            #Yup
            `cd foo/*;git commit -a -m \"$git_message\";git push; sleep 1; git push`;
            return 1;
        }
        #Nope no changes
        return 0;
    }
}

sub handle_group_cmd {
    my $git_message = shift @_;
    my $gate_regex = shift @_;
    my $gate_function = shift @_;
    my $fix_function = shift @_;
    return sub {
        my $changes = 0;
        my @files = @_;
        foreach my $file (@files) {
            if ($file !~ /\/\.git\// && $file =~ $gate_regex) {        
                $fix_function->($file);
            }
        }
        #Determine if we have made any difference
        `cd foo/*;git diff --exit-code`;
        if ($? != 0) {
            #Yup
            `cd foo/*;git commit -a -m \"$git_message\";git push; sleep 1; git push`;
            return 1;
        }
        #Nope no changes
        return 0;
    }
}
