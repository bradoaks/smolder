package Smolder::Build;
use strict;
use warnings;
use base 'Module::Build::TAPArchive';
use File::Temp;
use Cwd qw(cwd);
use File::Spec::Functions qw(catdir tmpdir);
use IPC::Run qw(start finish pump);
use LWP::UserAgent;
use WWW::Mechanize;

=head1 NAME

Smolder::Build

=head1 DESCRIPTION

L<Module::Build> subclass for Smolder specific testing and installation.

=head1 OVERRIDDEN ACTIONS

=head2 test

Make sure that we test against a new, empty SQLite db and that Smolder
is up and running before running the test files. Then make sure we shut
down Smolder when done.

=cut

my $HOSTNAME = 'localhost.localdomain';
my $PORT = '112234';
sub ACTION_test {
    my $self = shift;
    $self->_wrap_test_action('test');
}

sub ACTION_test_archive {
    my $self = shift;
    $self->_wrap_test_action('test_archive');
}

sub _wrap_test_action {
    my ($self, $action) = @_;
    my $cwd = cwd();

    # create a temporary database
    my $tmp_dir = File::Temp->newdir(template => 'smolder-XXXXXX');
    my $conf = "Port $PORT\nHostname $HOSTNAME\n"
        . "FromAddress smolder\@$HOSTNAME\nSecret ad01i11932lsk\n"
        . "TemplateDir '" . catdir($cwd, 'templates') . "'\n"
        . "HtdocsDir '" . catdir($cwd, 'htdocs') . "'\n"
        . "SQLDir '" . catdir($cwd, 'sql') . "'\n"
        . "DataDir '" . $tmp_dir->dirname . "'\n";

    my $tmp_conf = File::Temp->new(template => 'smolder-XXXXXX', suffix => '.conf', dir => tmpdir);
    print $tmp_conf $conf;
    close $tmp_conf;
    $ENV{SMOLDER_CONF} = $tmp_conf->filename;

    # start the smolder server
    my ($in, $out, $err);
    my $subprocess = start(["$cwd/bin/smolder"], \$in, \$out, \$err);
    my $tries = 0;
    warn "Waiting for Smolder to start...\n";
    while(!_is_smolder_running() && $tries < 7) {
        sleep(3);
    }

    my $method = "SUPER::ACTION_$action";
    $self->$method(@_);
    
    # finish() seems to hang, so just kill it
    $subprocess->kill_kill;
}

sub _is_smolder_running {
    my $url = "http://$HOSTNAME:$PORT/app";

    # Create a user agent object
    my $ua = LWP::UserAgent->new;
    $ua->timeout(4);
    my $res = $ua->get($url);

    # Check the outcome of the response
    return $res->is_success;
}

=head1 EXTRA ACTIONS

=head2 smoke

Run the smoke tests and submit them to our Smolder server.

=cut

__PACKAGE__->add_property(no_update => 0);
__PACKAGE__->add_property(tags => '');
__PACKAGE__->add_property(server => 'http://smolder.plusthree.com');
__PACKAGE__->add_property(project_id => 2);
sub ACTION_smoke {
    my $self = shift;
    my $p    = $self->{properties};
    if ($p->{no_update} or `svn update` =~ /Updated to/i) {

        $self->ACTION_test_archive();

        # now send the results off to smolder
        my $mech = WWW::Mechanize->new();
        $mech->get("$p->{server}/app");
        unless ($mech->status eq '200') {
            print "Could not reach $p->{server}/app successfully. Received status "
              . $mech->status . "\n";
            exit(1);
        }

        # now go to the add-smoke-report page for this project
        $mech->get("$p->{server}/app/public_projects/add_report/$p->{project_id}");
        if ($mech->status ne '200' || $mech->content !~ /New Smoke Report/) {
            print "Could not reach the Add Smoke Report form in Smolder!\n";
            exit(1);
        }
        $mech->form_name('add_report');
        my %fields = (
            report_file  => $p->{archive_file},
            platform     => `cat /etc/redhat-release`,
            architecture => `uname -m`,
        );
        $fields{tags} = $p->{tags} if $p->{tags};

        # get the comments from svn
        my @lines = `svn info`;
        @lines = grep { $_ =~ /URL|Revision|LastChanged/ } @lines;
        $fields{comments} = join("\n", @lines);
        $mech->set_fields(%fields);
        $mech->submit();

        my $content = $mech->content;
        if ($mech->status ne '200' || $content !~ /Recent Smoke Reports/) {
            print "Could not upload smoke report with the given information!\n";
            exit(1);
        }
        $content =~ /#(\d+) Added/;
        my $report_id = $1;

        print "\nReport successfully uploaded as #$report_id.\n";
        unlink($p->{archive_file}) if -e $p->{archive_file};

    } else {
        print "No updates to Smolder\n";
        exit(0);
    }
}

=head2 db

Create a new blank DB in the data/ directory (used for development)

=cut

sub ACTION_db {
    my $self = shift;
    $self->depends_on('build');
    require Smolder::DB;
    Smolder::DB->create_database();
}

=head2 update_smoke_html

Update all the HTML for the existing smoke reports. This is useful for development
and also upgrading when the report HTML template files have changed
and you want that change to propagate.

=cut

sub ACTION_update_smoke_html {
    my $self = shift;
    require Smolder::DB::SmokeReport;
    Smolder::DB::SmokeReport->update_all_report_html();
}

1;
