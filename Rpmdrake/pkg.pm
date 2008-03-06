package Rpmdrake::pkg;
#*****************************************************************************
#
#  Copyright (c) 2002 Guillaume Cottenceau
#  Copyright (c) 2002-2007 Thierry Vignaud <tvignaud@mandriva.com>
#  Copyright (c) 2003, 2004, 2005 MandrakeSoft SA
#  Copyright (c) 2005-2007 Mandriva SA
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License version 2, as
#  published by the Free Software Foundation.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
#*****************************************************************************
#
# $Id$

use strict;
use MDK::Common::Func 'any';
use lib qw(/usr/lib/libDrakX);
use common;
use POSIX qw(_exit);
use URPM;
use utf8;
use Rpmdrake::open_db;
use Rpmdrake::gurpm;
use Rpmdrake::formatting;
use Rpmdrake::rpmnew;

use rpmdrake;
use urpm;
use urpm::lock;
use urpm::install;
use urpm::signature;
use urpm::get_pkgs;
use urpm::select;
use urpm::main_loop;
use urpm::args qw();


use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(
                    download_callback
                    extract_header
                    find_installed_version
                    get_pkgs
                    parse_compssUsers_flat
                    perform_installation
                    perform_removal
                    run_rpm);

use mygtk2 qw(gtknew);
use ugtk2 qw(:all);
use Gtk2::Pango;
use Gtk2::Gdk::Keysyms;


sub parse_compssUsers_flat() {
    my (%compssUsers, $category);
    my $compss = '/var/lib/urpmi/compssUsers.flat';
    -r $compss or $compss = '/usr/share/rpmdrake/compssUsers.flat.default';
    -r $compss or do {
	print STDERR "No compssUsers.flat file found\n";
	return undef;
    };
    foreach (cat_($compss)) {
	s/#.*//;
	/^\s*$/ and next;
	if (/^\S/) {
	    if (/^(.+?) \[icon=.+?\] \[path=(.+?)\]/) {
		$category = translate($2) . '|' . translate($1);
	    } else {
		print STDERR "Malformed category in compssUsers.flat: <$_>\n";
	    }
	} elsif (/^\t(\d) (\S+)\s*$/) {
	    $category or print STDERR "Entry without category <$_>\n";
	    push @{$compssUsers{$2}}, $category . ($1 <= 3 ? '|' . N("Other") : '');
	}
    }
    \%compssUsers;
}

sub run_rpm {
    foreach (qw(LANG LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION LC_ALL)) {
        local $ENV{$_} = $ENV{$_} . '.UTF-8' if $ENV{$_} && $ENV{$_} !~ /UTF-8/;
    }
    my @l = map { ensure_utf8($_) } `@_`;
    wantarray() ? @l : join('', @l);
}


sub extract_header {
    my ($pkg, $urpm, $xml_info, $o_installed_version) = @_;
    my %fields = (
        info => 'description',
        files => 'files',
        changelog => 'changelog',
    );
    # already extracted:
    return if $pkg->{$fields{$xml_info}};

    my $p = $pkg->{pkg};
    my $name = urpm_name($p);
    # fix extracting info for SRPMS and RPM GPG keys:
    $name =~ s!\.src!!;

    if ($p->flag_installed && !$p->flag_upgrade) {
        my @files = map { chomp_($_) } run_rpm("rpm -ql $name");
	add2hash($pkg, { files => [ @files ? @files : N("(none)") ],
                         changelog => format_changelog_string($o_installed_version, scalar(run_rpm("rpm -q --changelog $name"))) });
    } else {
	my $medium = pkg2medium($p, $urpm);
        my ($local_source, %xml_info_pkgs, $bar_id);
        my $_statusbar_clean_guard = before_leaving { $bar_id and statusbar_msg_remove($bar_id) };
        my $dir = urpm::file_from_local_url($medium->{url});
        if ($dir) {
            $local_source = "$dir/" . $p->filename;
        }
        if (-e $local_source) {
            $bar_id = statusbar_msg(N("Getting information from XML meta-data from %s...", $dir), 0);
            $urpm->{log}("getting information from rpms from $dir");
        } else {
            my $gurpm;
            $bar_id = statusbar_msg(N("Getting '%s' from XML meta-data...", $xml_info), 0);
            my $_gurpm_clean_guard = before_leaving { undef $gurpm };
                if (my $xml_info_file = urpm::media::any_xml_info($urpm, $medium, $xml_info, undef, sub {
                                                                      $gurpm ||= Rpmdrake::gurpm->new(N("Please wait"), transient => $::main_window);
                                                                      download_callback($gurpm, @_)
                                                                        or goto header_non_available;
                                                                  })) {
                    require urpm::xml_info;
                    require urpm::xml_info_pkg;
                    $urpm->{log}("getting information from $xml_info_file");
                    my %nodes = eval { urpm::xml_info::get_nodes($xml_info, $xml_info_file, [ $name ]) };
                    goto header_non_available if $@;
                    put_in_hash($xml_info_pkgs{$name} ||= {}, $nodes{$name});
                } else {
                    if ($xml_info eq 'info') {
                        $urpm->{info}(N("No xml info for medium \"%s\", only partial result for package %s", $medium->{name}, $name));
                    } else {
                        $urpm->{error}(N("No xml info for medium \"%s\", unable to return any result for package %s", $medium->{name}, $name));
                    }
                }
	}

        #- even if non-root, search for a header in the global cachedir
        my $file = $local_source;
        if (-s $file) {
            $p->update_header($file) or do {
		warn "Warning, could not extract header for $name from $medium!";
		goto header_non_available;
	    };
	    add2hash($pkg, { description => rpm_description($p->description),
	        files => scalar($p->files) ? [ $p->files ] : [ N("(none)") ],
		changelog => format_changelog_changelogs($o_installed_version, $p->changelogs) });
	    $p->pack_header; # needed in order to call methods on objects outside ->traverse
        } elsif ($xml_info_pkgs{$name}) {
            if ($xml_info eq 'info') {
                add2hash($pkg, { description => rpm_description($xml_info_pkgs{$name}{description}) });
            } elsif ($xml_info eq 'files') {
                my @files = map { chomp_(to_utf8($_)) } split("\n", $xml_info_pkgs{$name}{files});
                add2hash($pkg, { files => [ @files ? @files : N("(none)") ] });
            } elsif ($xml_info eq 'changelog') {
                add2hash($pkg, { 
                    changelog => format_changelog_changelogs($o_installed_version,
                                                             @{$xml_info_pkgs{$name}{changelogs}})
                });
            }
	    $p->pack_header; # needed in order to call methods on objects outside ->traverse
        } else {
            goto header_non_available;
        }
        return;
           header_non_available:
             add2hash($pkg, { summary => $p->summary || N("(Not available)"), description => undef });
    }
}

sub find_installed_version {
    my ($p) = @_;
    my @version;
    open_rpm_db()->traverse_tag('name', [ $p->name ], sub { push @version, $_[0]->version . '-' . $_[0]->release });
    @version ? join(',', sort @version) : N("(none)");
}

my $canceled;
sub download_callback {
    my ($gurpm, $mode, $file, $percent, $total, $eta, $speed) = @_;
    $canceled = 0;
    if ($mode eq 'start') {
        $gurpm->label(N("Downloading package `%s'...", basename($file)));
        $gurpm->validate_cancel(but(N("Cancel")), sub { $canceled = 1 });
    } elsif ($mode eq 'progress') {
        $gurpm->label(
            join("\n",
                 N("Downloading package `%s'...", basename($file)),
                 (defined $total && defined $eta ?
                    N("        %s%% of %s completed, ETA = %s, speed = %s", $percent, $total, $eta, $speed)
                      : N("        %s%% completed, speed = %s", $percent, $speed)
                  ) =~ /^\s*(.*)/
              ),
        );
        $gurpm->progress($percent/100);
    } elsif ($mode eq 'end') {
        $gurpm->progress(1);
        $gurpm->invalidate_cancel;
    }
    !$canceled;
}


# -=-=-=---=-=-=---=-=-=-- install packages -=-=-=---=-=-=---=-=-=-

my (@update_medias, $is_update_media_already_asked);

sub get_update_medias {
    my ($urpm) = @_;
    grep { !$_->{ignore} && $_->{update} } @{$urpm->{media}};
}

sub warn_about_media {
    my ($w, $opts) = @_;

    return if !member($::default_list_mode, qw(all_updates security bugfix normal));
    return if $::rpmdrake_options{'no-media-update'};

    # we use our own instance of the urpmi db in order not to mess up with skip-list managment (#31092):
    # and no need to fully configure urpmi since we may have to do it again anyway because of new media:
    my $urpm = fast_open_urpmi_db();

    my $_lock = urpm::lock::urpmi_db($urpm, undef, wait => $urpm->{options}{wait_lock});

    # build media list:
    @update_medias = get_update_medias($urpm);

    # do not update again media after installing/removing some packages:
    $::rpmdrake_options{'no-media-update'} ||= 1;

	    if (@update_medias > 0) {
		if (!$opts->{skip_updating_mu} && !$is_update_media_already_asked) {
              $is_update_media_already_asked = 1;
		     $::rpmdrake_options{'no-confirmation'} or interactive_msg_with_banner(N("Confirmation"),
N("I need to contact the mirror to get latest update packages.
Please check that your network is currently running.

Is it ok to continue?"), yesno => 1,
                   widget =>  gtknew('CheckButton', text => N("Do not ask me next time"),
                                     active_ref => \$::rpmdrake_options{'no-confirmation'}
                                 )) or myexit(-1);
		    writeconf();
		    urpm::media::select_media($urpm, map { $_->{name} } @update_medias);
		    update_sources($urpm, noclean => 1, banner => $::isEmbedded);
		}
	    } else {
		if (any { $_->{update} } @{$urpm->{media}}) {
		    interactive_msg(N("Already existing update media"),
N("You already have at least one update medium configured, but
all of them are currently disabled. You should run the Software
Media Manager to enable at least one (check it in the \"%s\"
column).

Then, restart \"%s\".", N("Enabled"), $rpmdrake::myname_update));
		    myexit(-1);
		}
		my ($mirror) = choose_mirror($urpm, transient => $w->{real_window} || $::main_window,
                                       message => join("\n\n",
                                                       N("You have no configured update media. MandrivaUpdate cannot operate without any update media."),
                                                       N("I need to contact the Mandriva website to get the mirror list.
Please check that your network is currently running.

Is it ok to continue?"),
                                                         ),
                                   );
		my $m = ref($mirror) ? $mirror->{url} : '';
		$m or interactive_msg(N("How to choose manually your mirror"),
N("You may also choose your desired mirror manually: to do so,
launch the Software Media Manager, and then add a `Security
updates' medium.

Then, restart %s.", $rpmdrake::myname_update)), myexit(-1);
		add_distrib_update_media($urpm, $mirror, only_updates => 1);
	    }
}


sub get_parallel_group() {
    $::rpmdrake_options{parallel} ? $::rpmdrake_options{parallel}[0] : undef;
}


urpm::select::add_packages_to_priority_upgrade_list('rpmdrake');

my ($restart_itself, $priority_state, $priority_requested);

our $probe_only_for_updates;
sub get_pkgs {
    my ($opts) = @_;
    my $w = $::main_window;

    my $gurpm = Rpmdrake::gurpm->new(1 ? N("Please wait") : N("Package installation..."), N("Initializing..."), transient => $::main_window);
    my $_gurpm_clean_guard = before_leaving { undef $gurpm };
    #my $_flush_guard = Gtk2::GUI_Update_Guard->new;

    warn_about_media($w, $opts);

    my $urpm = open_urpmi_db(update => $probe_only_for_updates);

    my $_drop_lock = before_leaving { undef $urpm->{lock} };

    # update media list in case warn_about_media() added some:
    @update_medias = get_update_medias($urpm);

    $gurpm->label(N("Reading updates description"));
    $gurpm->progress(0.05);

	#- parse the description file
    my $update_descr = urpm::get_updates_description($urpm, @update_medias);

    my $_unused = N("Please wait, finding available packages...");

    # find out installed packages:

    my $level = 0.05;
    my $total = @{$urpm->{depslist}};
    $gurpm->label(N("Please wait, listing base packages..."));
    $gurpm->progress($level);

    my ($count, $prev_stage, $new_stage, $limit);
    
    my $reset_update = sub { undef $prev_stage; $count = 0; $limit = $_[0] };
    my $update = sub {
        return if !$total; # don't die if there's no source
        $count++;
        $new_stage = $level+($limit-$level)*$count/$total;
        if ($prev_stage + 0.01 < $new_stage) {
            $prev_stage = $new_stage;
            $gurpm->progress($new_stage);
        }
    };

    my @base = ("basesystem", split /,\s*/, $urpm->{global_config}{'prohibit-remove'});
    my (%base, %basepackages);
    my $db = open_rpm_db();
    my $sig_handler = sub { undef $db; exit 3 };
    local $SIG{INT} = $sig_handler;
    local $SIG{QUIT} = $sig_handler;
    $reset_update->(0.33);
    while (defined(local $_ = shift @base)) {
	exists $basepackages{$_} and next;
	$db->traverse_tag(m|^/| ? 'path' : 'whatprovides', [ $_ ], sub {
			      $update->();
			      push @{$basepackages{$_}}, urpm_name($_[0]);
			      push @base, $_[0]->requires_nosense;
			  });
    }
    foreach (values %basepackages) {
	my $n = @$_; #- count number of times it's provided
	foreach (@$_) {
	    $base{$_} = \$n;
	}
    }
    $gurpm->label(N("Please wait, finding installed packages..."));
    $gurpm->progress($level = 0.33);
    $reset_update->(0.66);
    my (@installed_pkgs, %all_pkgs);
    if (!$probe_only_for_updates) {
    $db->traverse(sub {
	    my ($pkg) = @_;
	    $update->();
	    my $fullname = urpm_name($pkg);
	    #- Extract summary and description since they'll be lost when the header is packed
	    $all_pkgs{$fullname} = {
		selected => 0, pkg => $pkg, urpm_name => urpm_name($pkg),
		summary => $pkg->summary,
		description => rpm_description($pkg->description),
	    } if !($all_pkgs{$fullname} && $all_pkgs{$fullname}{description});
	    if (my $name = $base{$fullname}) {
		$all_pkgs{$fullname}{base} = \$name;
		$pkg->set_flag_base(1) if $$name == 1;
	    }
         push @installed_pkgs, $fullname;
	    $pkg->pack_header; # needed in order to call methods on objects outside ->traverse
	});
    }

    if (my $group = get_parallel_group()) {
        urpm::media::configure($urpm, parallel => $group);
    }

    # find out availlable packages:

    $urpm->{state} = {};
    my (@installable_pkgs, @updates);

    $gurpm->label(N("Please wait, finding available packages..."));
    $gurpm->progress($level = 0.66);

    check_update_media_version($urpm, @update_medias);

    my $requested = {};
    my $state = {};

    # list of updates (including those matching /etc/urpmi/skip.list):
    my @requested;

    # list of pure updates (w/o those matching /etc/urpmi/skip.list but with their deps):
    my @requested_strict;

    #- return value is true if program should be restarted (in order to take care of important
    #- packages being upgraded (urpmi, perl-URPM, rpm, glibc, ...).
    $restart_itself = urpm::select::resolve_dependencies(
        $urpm, $state, $requested,
        callback_choices => \&Rpmdrake::gui::callback_choices,
        priority_upgrade => $urpm->{options}{'priority-upgrade'},
        auto_select => 1,
        only_request_packages_to_upgrade => !$probe_only_for_updates,
        upgrade_callback => sub {
            my ($requested) = @_;
            @requested = sort map { urpm_name($_) } @{$urpm->{depslist}}[keys %$requested];
        },
        if_($probe_only_for_updates,
           resolve_req_callback => sub { @requested_strict = sort map { urpm_name($_) } @_ }
       ),
    );

    # list updates including skiped ones + their deps in MandrivaUpdate:
    @requested = uniq(@requested, @requested_strict) if $probe_only_for_updates;

    $priority_state = $restart_itself ? $state : undef;
    $priority_requested = $restart_itself ? $requested : undef;

    if (!$probe_only_for_updates) {
        $urpm->compute_installed_flags($db); # TODO/FIXME: not for updates
        $urpm->{depslist}[$_]->set_flag_installed foreach keys %$requested; #- pretend it's installed
    }
    $urpm->{rpmdrake_state} = $state; #- Don't forget it
    $gurpm->progress($level = 0.7);

    my @search_medias = grep { $_->{searchmedia} } @{$urpm->{media}};

    my @backports;
    $reset_update->(1);
    foreach my $pkg (@{$urpm->{depslist}}) {
        $update->();
	$pkg->flag_upgrade or next;
        my $name = urpm_name($pkg);
        push @installable_pkgs, $name;
        $all_pkgs{$name} = { pkg => $pkg, summary => $pkg->summary };
    }
    foreach my $medium (@search_medias) {
        $update->();
      foreach my $pkg_id ($medium->{start} .. $medium->{end}) {
          next if !$pkg_id;
          my $pkg = $urpm->{depslist}[$pkg_id];
          $pkg->flag_upgrade or next;
          my $name = urpm_name($pkg);
	  	push @backports, $name;
          $all_pkgs{$name} = { pkg => $pkg, summary => $pkg->summary };
      }
    }
    foreach my $medium (@update_medias) {
        $update->();
      foreach my $pkg_id ($medium->{start} .. $medium->{end}) {
          my $pkg = $urpm->{depslist}[$pkg_id];
          $pkg->flag_upgrade or next;
        my $selected = 0;
        my $name = urpm_name($pkg);

	if (member($name, @requested)) {
             # selecting updates by default but skipped ones (MandrivaUpdate only):
             $selected = member($name, @requested_strict);
            push @updates, $name;
	}
        $all_pkgs{urpm_name($pkg)} = { selected => $selected, pkg => $pkg,
                                       summary => $pkg->summary,
                                   };
      }
    }

    $all_pkgs{$_}{pkg}->set_flag_installed foreach @installed_pkgs;

    # urpmi only care about the first medium where it found the package,
    # so there's no need to list the same package several time:
    @installable_pkgs = uniq(difference2(\@installable_pkgs, \@updates));
 
    my @gui_pkgs = map { chomp; $_ } cat_('/usr/share/rpmdrake/gui.lst');

    +{ urpm => $urpm,
       all_pkgs => \%all_pkgs,
       installed => \@installed_pkgs,
       installable => \@installable_pkgs,
       updates => \@updates,
       meta_pkgs => [ grep { /^task-/ } keys %all_pkgs ],
       gui_pkgs => [ grep { member(($all_pkgs{$_}{pkg}->fullname)[0], @gui_pkgs) } keys %all_pkgs ],
       update_descr => $update_descr,
       backports => \@backports,
   };
}

sub display_READMEs_if_needed {
    my ($urpm, $w) = @_;
    return if !$urpm->{readmes};
    my %Readmes = %{$urpm->{readmes}};
    if (keys %Readmes) {        #- display the README*.urpmi files
        interactive_packtable(
            N("Upgrade information"),
            $w,
            N("These packages come with upgrade information"),
            [ map {
                my $fullname = $_;
                [ gtkpack__(
                    gtknew('HBox'),
                    gtkset_selectable(gtknew('Label', text => $Readmes{$fullname}),1),
                ),
                  gtksignal_connect(
                      gtknew('Button', text => N("Upgrade information about this package")),
                      clicked => sub {
                          interactive_msg(
                              N("Upgrade information about package %s", $Readmes{$fullname}),
                              (join '' => formatAlaTeX(scalar cat_($fullname))),
                              scroll => 1,
                          );
                      },
                  ),
		    ] } keys %Readmes ],
            [ gtknew('Button', text => N("Ok"), clicked => sub { Gtk2->main_quit }) ]
        );
    }
}

sub perform_parallel_install {
    my ($urpm, $group, $w, $statusbar_msg_id) = @_;
    my @pkgs = map { if_($_->flag_requested, urpm_name($_)) } @{$urpm->{depslist}};

    my @error_msgs;
    my $res = !run_program::run('urpmi', '2>', \@error_msgs, '-v', '--X', '--parallel', $group, @pkgs);

    if ($res) {
        $$statusbar_msg_id = statusbar_msg(
            #N("Everything installed successfully"),
            N("All requested packages were installed successfully."),
        );
    } else {
        interactive_msg(
            N("Problem during installation"),
            N("There was a problem during the installation:\n\n%s", join("\n", @error_msgs)),
            scroll => 1,
        );
    }
    open_rpm_db('force_sync');
    $w->set_sensitive(1);
    return 0;
}

sub perform_installation {  #- (partially) duplicated from /usr/sbin/urpmi :-(
    my ($urpm, $pkgs) = @_;

    my @error_msgs;
    my $statusbar_msg_id;
    my $gurpm;
    local $urpm->{fatal} = sub {
        my $fatal_msg = $_[1];
        printf STDERR "Fatal: %s\n", $fatal_msg;
        undef $gurpm;
        interactive_msg(N("Installation failed"),
                        N("There was a problem during the installation:\n\n%s", $fatal_msg));
        goto return_with_exit_code;
    };
    local $urpm->{error} = sub { printf STDERR "Error: %s\n", $_[0]; push @error_msgs, $_[0] };

    my $w = $::main_window;
    $w->set_sensitive(0);
    my $_restore_sensitive = before_leaving { $w->set_sensitive(1) };

    my $_flush_guard = Gtk2::GUI_Update_Guard->new;

    if (my $group = get_parallel_group()) {
        return perform_parallel_install($urpm, $group, $w, \$statusbar_msg_id);
    }

    my $lock = urpm::lock::urpmi_db($urpm, undef, wait => $urpm->{options}{wait_lock});
    my $rpm_lock = urpm::lock::rpm_db($urpm, 'exclusive');
    my $state = $priority_state || $probe_only_for_updates ? { } : $urpm->{rpmdrake_state};

    my $bar_id = statusbar_msg(N("Checking validity of requested packages..."), 0);

    # select packages to install / enssure selected pkg set is consistant:
    my $requested = { map { $_->id => undef } grep { $_->flag_selected } @{$urpm->{depslist}} };
    $restart_itself = urpm::select::resolve_dependencies(
        $urpm, $state, $requested,
        callback_choices => \&Rpmdrake::gui::callback_choices,
        priority_upgrade => $urpm->{options}{'priority-upgrade'},
    );
    statusbar_msg_remove($bar_id);

    my ($local_sources, $list) = urpm::get_pkgs::selected2list($urpm, 
	$state->{selected},
    );
    if (!$local_sources && (!$list || !@$list)) {
        interactive_msg(
	    N("Unable to get source packages."),
	    N("Unable to get source packages, sorry. %s",
		@error_msgs ? N("\n\nError(s) reported:\n%s", join("\n", @error_msgs)) : ''),
	    scroll => 1,
	);
        goto return_with_exit_code;
    }

    my @pkgs = map { scalar($_->fullname) } sort(grep { $_->flag_selected } @{$urpm->{depslist}}[keys %{$state->{selected}}]);#{ $a->name cmp $b->name } @{$urpm->{depslist}}[keys %{$state->{selected}}];
    @{$urpm->{ask_remove}} = sort urpm::select::removed_packages($urpm, $urpm->{state});
    my @to_remove = map { if_($pkgs->{$_}{selected} && !$pkgs->{$_}{pkg}->flag_upgrade, $pkgs->{$_}{urpm_name}) } keys %$pkgs;

    my $r = format_list(map { scalar(urpm::select::translate_why_removed_one($urpm, $urpm->{state}, $_)) } @to_remove);

    my ($size, $filesize) = $urpm->selected_size_filesize($state);
    my $install_count = int(@pkgs);
    my $to_install = $install_count == 0 ? '' :
      ($priority_state ? N("Rpmdrake or one of its priority dependencies needs to be updated first. Rpmdrake will then restart.") . "\n\n" : '') .
      (P("The following package is going to be installed:", "The following %d packages are going to be installed:", $install_count, $install_count)
      . "\n\n" . format_list(map { s!.*/!!; $_ } @pkgs));
    my $remove_count =  scalar(@to_remove);
    interactive_msg(($to_install ? N("Confirmation") : N("Some packages need to be removed")),
                    join("\n\n", 
                     ($r ? 
                        (!$to_install ? (P("Remove one package?", "Remove %d packages?", $remove_count, $remove_count), $r) :
 (($remove_count == 1 ?
 N("The following package has to be removed for others to be upgraded:")
   : N("The following packages have to be removed for others to be upgraded:")), $r), if_($to_install, $to_install))
                          : $to_install),
                         format_size($size),
                           $filesize ? N("%s of packages will be retrieved.", formatXiB($filesize))
                             : (),
                         N("Is it ok to continue?")),
                     scroll => 1,
                     yesno => 1) or return 1;

    my $_umount_guard = before_leaving { urpm::removable::try_umounting_removables($urpm) };

    # select packages to uninstall for !update mode:
    perform_removal($urpm, { map { $_ => $pkgs->{$_} } @to_remove }) if !$probe_only_for_updates;

    $gurpm = Rpmdrake::gurpm->new(1 ? N("Please wait") : N("Package installation..."), N("Initializing..."), transient => $::main_window);
    my $_gurpm_clean_guard = before_leaving { undef $gurpm };
    my $something_installed;

    my ($progress, $total, @rpms_upgrade);
    my $transaction;
    my ($progress_nb, $transaction_progress_nb, $remaining, $done);
    my $callback_inst = sub {
        my ($urpm, $type, $id, $subtype, $amount, $total) = @_;
        my $pkg = defined $id ? $urpm->{depslist}[$id] : undef;
        if ($subtype eq 'start') {
            if ($type eq 'trans') {
                $gurpm->label(1 ? N("Preparing packages installation...") : N("Preparing package installation transaction..."));
                } elsif (defined $pkg) {
                    $something_installed = 1;
                    $gurpm->label(N("Installing package `%s' (%s/%s)...", $pkg->name, ++$transaction_progress_nb, scalar(@{$transaction->{upgrade}}))
                                             . "\n" . N("Total: %s/%s", ++$progress_nb, $install_count));
                }
        } elsif ($subtype eq 'progress') {
            $gurpm->progress($total ? $amount/$total : 1);
        }
    };

    my $exit_code = 
      urpm::main_loop::run($urpm, $state, undef, undef, $requested,
                         {
                             completed => sub {
                                 # explicitly destroy the progress window when it's over; we may
                                 # have sg to display before returning (errors, rpmnew/rpmsave, ...):
                                 undef $gurpm;
                                       
                                 undef $lock;
                                 undef $rpm_lock;
                             },
                             inst => $callback_inst,
                             trans => $callback_inst,
                             ask_yes_or_no => sub {
                                 # handle 'allow-force' and 'allow-nodeps' options:
                                 my ($title, $msg) = @_;
                                 local $::main_window = $gurpm->{mainw}{real_window};
                                 interactive_msg($title, $msg, yesno => 1, scroll => 1,
                                 ) or goto return_with_exit_code;
                             },
                             message => sub {
                                 my ($title, $message) = @_;
                                 interactive_msg($title, $message, scroll => 1);
                             },
                             trans_log => sub { download_callback($gurpm, @_) or goto return_with_exit_code },
                             post_extract => sub {
                                 my ($set, $transaction_sources, $transaction_sources_install) = @_;
                                 $transaction = $set;
                                 $transaction_progress_nb = 0;
                                 $done += grep { !/\.src\.rpm$/ } values %$transaction_sources;         #updates
                                 $total = keys(%$transaction_sources_install) + keys %$transaction_sources;
                                 push @rpms_upgrade, grep { !/\.src\.rpm$/ } values %$transaction_sources;
                                 $done += grep { !/\.src\.rpm$/ } values %$transaction_sources_install; # installs
                             },
                             pre_removable => sub {
                                 # Gtk2::GUI_Update_Guard->new use of alarm() kill us when
                                 # running system(), thus making DVD being ejected and printing
                                 # wrong error messages (#30463)
                                       
                                 local $SIG{ALRM} = sub { die "ALARM" };
                                 $remaining = alarm(0);
                             },

                             post_removable => sub { alarm $remaining },
                             copy_removable => sub {
                                 my ($medium) = @_;
                                 interactive_msg(
                                     N("Change medium"),
                                     N("Please insert the medium named \"%s\"", $medium),
                                     yesno => 1, text => { no => N("Cancel"), yes => N("Ok") },
                                 );
                             },
                             pre_check_sig => sub { $gurpm->label(N("Verifying package signatures...")) },
                             check_sig => sub { $gurpm->progress(++$progress/$total) },
                             bad_signature => sub {
                                 my ($msg, $msg2) = @_;
                                 local $::main_window = $gurpm->{mainw}{real_window};
                                 $msg =~ s/:$/\n\n/m; # FIXME: to be fixed in urpmi after 2008.0
                                 interactive_msg(
                                     N("Warning"), "$msg\n\n$msg2", yesno => 1, if_(10 < ($msg =~ tr/\n/\n/), scroll => 1),
                                 ) or goto return_with_exit_code;
                             },
                             post_download => sub {
                                 $canceled and goto return_with_exit_code;
                                 $gurpm->invalidate_cancel_forever;
                             },
                             trans_error_summary => sub {
                                 my ($nok, $errors) = @_;
                                 interactive_msg(
                                     N("Problem during installation"),
                                     if_($nok, N("%d installation transactions failed", $nok) . "\n\n") .
                                       N("There was a problem during the installation:\n\n%s",
                                         join("\n\n", @$errors, @error_msgs)),
                                     scroll => 1,
                                 );
                             },
                             success_summary => sub {
                                 if (!($done || @to_remove)) {
                                     interactive_msg(N("Error"),
                                                     N("Unrecoverable error: no package found for installation, sorry."));
                                     return;
                                 }
                                 my $id = statusbar_msg(N("Inspecting configuration files..."), 0);
                                 my %pkg2rpmnew;
                                 foreach my $u (@rpms_upgrade) {
                                     $u =~ m|/([^/]+-[^-]+-[^-]+)\.[^\./]+\.rpm$|
                                       and $pkg2rpmnew{$1} = [ grep { m|^/etc| && (-r "$_.rpmnew" || -r "$_.rpmsave") }
                                                                 map { chomp_($_) } run_rpm("rpm -ql $1") ];
                                 }
                                 statusbar_msg_remove($id);
                                 dialog_rpmnew(N("The installation is finished; everything was installed correctly.

Some configuration files were created as `.rpmnew' or `.rpmsave',
you may now inspect some in order to take actions:"),
                                               %pkg2rpmnew)
                                   and statusbar_msg(N("All requested packages were installed successfully."), 1);
                                 statusbar_msg(N("Looking for \"README\" files..."), 1);
                                 display_READMEs_if_needed($urpm, $w);
                             },
                             already_installed_or_not_installable => sub {
                                 my ($msg1, $msg2) = @_;
                                 interactive_msg(N("Error"), join("\n", @$msg1, @$msg2));                                
                             },
                         },
                     );

    #- restart rpmdrake if needed, keep command line for that.
    if ($restart_itself && !$exit_code) {
        log::explanations("restarting rpmdrake");
        #- added --previous-priority-upgrade to allow checking if yet if
        #-   priority-upgrade list has changed. and make sure we don't uselessly restart
        my @argv = ('--previous-priority-upgrade=' . $urpm->{options}{'priority-upgrade'}, 
                grep { !/^--no-priority-upgrade$|--previous-priority-upgrade=/ } @Rpmdrake::init::ARGV_copy);
        run_program::raw({ detach => 1 }, $0, @argv);
        exit(0);
    }

    N("RPM transaction %d/%d");
    N("Unselect all");
    N("Details"); N("Filter");

    statusbar_msg_remove($statusbar_msg_id); #- XXX maybe remove this

  return_with_exit_code:
    return !($something_installed || scalar(@to_remove));
}


# -=-=-=---=-=-=---=-=-=-- remove packages -=-=-=---=-=-=---=-=-=-

sub perform_removal {
    my ($urpm, $pkgs) = @_;
    my @toremove = map { if_($pkgs->{$_}{selected}, $pkgs->{$_}{urpm_name}) } keys %$pkgs;
    return if !@toremove;
    my $gurpm = Rpmdrake::gurpm->new(1 ? N("Please wait") : N("Please wait, removing packages..."), N("Initializing..."), transient => $::main_window);
    my $_gurpm_clean_guard = before_leaving { undef $gurpm };

    my $progress = -1;
    local $urpm->{log} = sub {
        my $str = $_[0];
        print $str;
        $progress++;
        return if $progress <= 0; # skip first "creating transaction..." message
        $gurpm->label($str); # display "removing package %s"
        $gurpm->progress(min(0.99, scalar($progress/@toremove)));
        gtkflush();
    };

    my @results;
    slow_func_statusbar(
	N("Please wait, removing packages..."),
	$::main_window,
	sub {
	    @results = $::rpmdrake_options{parallel}
		? urpm::parallel::remove($urpm, \@toremove)
		: urpm::install::install($urpm, \@toremove, {}, {},
                                   callback_report_uninst => sub { $gurpm->label($_[0]) },
                               );
	    open_rpm_db('force_sync');
	},
    );
    if (@results) {
	interactive_msg(
	    N("Problem during removal"),
	    N("There was a problem during the removal of packages:\n\n%s", join("\n",  @results)),
	    if_(@results > 1, scroll => 1),
	);
	return 1;
    } else {
	return 0;
    }
}

1;
