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
use Rpmdrake::gurpm;
use Rpmdrake::formatting;
use Rpmdrake::rpmnew;

use rpmdrake;
use urpm::lock;
use urpm::install;
use urpm::signature;
use urpm::get_pkgs;
use urpm::select;


use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(extract_header find_installed_version formatlistpkg get_pkgs open_db parse_compssUsers_flat perform_installation perform_removal run_rpm $db);

use mygtk2 qw(gtknew);
use ugtk2 qw(:all);
use Gtk2::Pango;
use Gtk2::Gdk::Keysyms;

our $db;

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
        local $ENV{$_} = $ENV{$_} . '.UTF-8' if !/UTF-8/;
    }
    my @l = map { to_utf8($_) } `@_`;
    wantarray() ? @l : join('', @l);
}


sub extract_header {
    my ($pkg, $urpm) = @_;
    my $chg_prepro = sub {
	#- preprocess changelog for faster TextView insert reaction
	[ map { [ "$_\n", if_(/^\*/, { 'weight' => Gtk2::Pango->PANGO_WEIGHT_BOLD }) ] } split("\n", $_[0]) ];
    };
    my $name = urpm_name($pkg->{pkg});
    if ($pkg->{pkg}->flag_installed && !$pkg->{pkg}->flag_upgrade) {
	add2hash($pkg, { files => [ split /\n/, chomp_(scalar(run_rpm("rpm -ql $name"))) || N("(none)") ],
                         changelog => $chg_prepro->(scalar(run_rpm("rpm -q --changelog $name"))) });
    } else {
	my ($p, $medium) = ($pkg->{pkg}, pkg2medium($pkg->{pkg}, $urpm));
	my $hdlist = urpm::media::any_hdlist($urpm, $medium);
	$hdlist =~ s!^file:/+!!;
	if (-r $hdlist) {
	    my $packer;
         require MDV::Packdrakeng; 
         eval { $packer = MDV::Packdrakeng->open(archive => $hdlist, quiet => 1) } or do {
		    warn "Warning, hdlist $hdlist seems corrupted ($@)\n";
		    goto header_non_available;
		};
            my ($headersdir, $retries);
         while (!-d $headersdir && $retries < 5) {
             $headersdir = chomp_(`mktemp -d /tmp/rpmdrake.XXXXXXXX`);
             $retries++;
             -d $headersdir or warn qq(Could not create temporary directory "$headersdir");
         }
         -d $headersdir or  do {
             warn "Warning, could not extract header!";
             goto header_non_available;
	    };
	    $packer->extract($headersdir, $p->header_filename);
	    $p->update_header("$headersdir/" . $p->header_filename) or do {
		warn "Warning, could not extract header!";
		goto header_non_available;
	    };
	    rm_rf($headersdir);
	    add2hash($pkg, { summary => rpm_summary($p->summary), description => rpm_description($p->description) });
	    add2hash($pkg, {
	        files => scalar($p->files) ? [ $p->files ] : [ N("(none)") ],
		changelog => $chg_prepro->(join("\n", mapn { "* " . localtime2changelog($_[2]) . " $_[0]\n\n$_[1]\n" }
						[ $p->changelog_name ], [ $p->changelog_text ], [ $p->changelog_time ])) });
	    $p->pack_header;
	} else {
           header_non_available:
             add2hash($pkg, { summary => $p->summary || N("(Not available)"), description => undef });
	}
    }
}

my %options;

sub open_db {
    my ($o_force) = @_;
    my $host;
    log::explanations("opening the RPM database");
    if ($options{parallel} && ((undef, $host) = @{$options{parallel}})) {
        my $done if 0;
        my $dblocation = "/var/cache/urpmi/distantdb/$host";
        if (!$done || $o_force) {
            print "syncing db from $host to $dblocation...";
            mkdir_p "$dblocation/var/lib/rpm";
            system "rsync -Sauz -e ssh $host:/var/lib/rpm/ $dblocation/var/lib/rpm";
            $? == 0 or die "Couldn't sync db from $host to $dblocation";
            $done = 1;
            print "done.\n";
        }
        $db = URPM::DB::open($dblocation) or die "Couldn't open RPM DB";
    } else {
        $db = URPM::DB::open or die "Couldn't open RPM DB";
    }
}


sub find_installed_version {
    my ($p) = @_;
    my @version;
    $db->traverse_tag('name', [ $p->name ], sub { push @version, $_[0]->version . '-' . $_[0]->release });
    @version ? join(',', sort @version) : N("(none)");
}

sub formatlistpkg { join("\n", sort { uc($a) cmp uc($b) } @_) }


# -=-=-=---=-=-=---=-=-=-- install packages -=-=-=---=-=-=---=-=-=-


sub get_pkgs {
    my ($urpm, $opts) = @_;
    my $update_name = 'update_source';
    my %update_descr;
    my @update_medias;
    my $w = $::main_window;

    my $error_happened;
    my $fatal_handler = sub {
        $error_happened = 1;
        interactive_msg(N("Fatal error"),
                         N("A fatal error occurred: %s.", $_[1]));
        myexit(-1) if 0; #FIXME
    };

    Rpmdrake::gurpm::init(1 ? N("Please wait") : N("Package installation..."), N("Initializing..."), transient => $::w->{real_window});
    my $_guard = before_leaving { Rpmdrake::gurpm::end() };

    if (!$urpm) {
        $urpm ||= urpm->new;
        $urpm->{fatal} = $fatal_handler;
        my $media = ref $::options{media} ? join(',', @{$::options{media}}) : '';
        urpm::media::configure($urpm, media => $media);
        if ($error_happened) {
            touch('/etc/urpmi/urpmi.cfg');
            exec('edit-urpm-sources.pl');
        }
    }
    my $_lock = urpm::lock::urpmi_db($urpm);
    my $statedir = $urpm->{statedir};
    @update_medias = grep { !$_->{ignore} && $_->{update} } @{$urpm->{media}};


        $urpm->{fatal} = $fatal_handler;
    if (member($::default_list_mode, qw(all_updates security bugfix normal))) {
	unless ($::options{'no-media-update'}) {
	    if (@update_medias > 0) {
		if (!$opts->{skip_updating_mu}) {
		    $::options{'no-confirmation'} or interactive_msg_with_banner(N("Confirmation"),
N("I need to contact the mirror to get latest update packages.
Please check that your network is currently running.

Is it ok to continue?"), yesno => 1) or myexit(-1);
		    urpm::media::select_media($urpm, map { $_->{name} } @update_medias);
		    update_sources($urpm, noclean => 1, banner => $::isEmbedded);
		}
	    } else {
		if (any { $_->{update} } @{$urpm->{media}}) {
		    interactive_msg(N("Already existing update media"),
N("You already have at least one update medium configured, but
all of them are currently disabled. You should run the Software
Media Manager to enable at least one (check it in the Enabled?
column).

Then, restart %s.", $rpmdrake::myname_update));
		    myexit(-1);
		}
	      mu_retry_another_mirror:
		my ($mirror) = choose_mirror(if_(exists $w->{real_window}, transient => $w->{real_window}));
		my $m = ref($mirror) ? $mirror->{url} : '';
		$m or interactive_msg(N("How to choose manually your mirror"),
N("You may also choose your desired mirror manually: to do so,
launch the Software Media Manager, and then add a `Security
updates' medium.

Then, restart %s.", $rpmdrake::myname_update)), myexit(-1);
		add_medium_and_check(
		    $urpm, {},
		    $update_name, make_url_mirror($m), 'media_info/synthesis.hdlist.cz', update => 1,
		);
		@update_medias = { name => $update_name };  #- hack to simulate a medium for parsing of descriptions
	    }
	}
    }

    Rpmdrake::gurpm::label(N("Reading updates description"));
    Rpmdrake::gurpm::progress(0.05);
	my ($cur, $section);
	#- parse the description file
    foreach my $medium (@update_medias) {
        foreach (cat_("$statedir/descriptions.$medium->{name}")) {
            /^%package +(.+)/ and do {
                my @pkg_list = split /\s+/, $1;
                 exists $cur->{importance} && $cur->{importance} !~ /^(?:security|bugfix)\z/
                   and $cur->{importance} = 'normal';
                $update_descr{$_} = $cur foreach @{$cur->{pkgs} || []};
                $cur = { pkgs => \@pkg_list, medium => $medium->{name} };
                $section = 'pkg';
                next;
            };
            /^%(pre|description)/ and do { $section = $1; next };
            /^Updated?: +(.+)/ && $section eq 'pkg'
              and do { $cur->{update} = $1; next };
            /^Importance: +(.+)/ && $section eq 'pkg'
              and do { $cur->{importance} = $1; next };
            /^(ID|URL): +(.+)/ && $section eq 'pkg'
              and do { $cur->{$1} = $2; next };
            $section =~ /^(pre|description)\z/ and $cur->{$1} .= $_;
        }
    }

    my $_unused = N("Please wait, finding available packages...");

    # find out installed packages:

    #$urpm = urpm->new;
    #$urpm->read_config;
    my $level = 0.05;
    my $total = @{$urpm->{depslist}};
    Rpmdrake::gurpm::label(N("Please wait, listing base packages..."));
    Rpmdrake::gurpm::progress($level);

    my ($count, $prev_stage, $new_stage, $limit);
    
    my $reset_update = sub { undef $prev_stage; $count = 0; $limit = $_[0] };
    my $update = sub {
        $count++;
        $new_stage = $level+($limit-$level)*$count/$total;
        if ($prev_stage + 0.01 < $new_stage) {
            $prev_stage = $new_stage;
            Rpmdrake::gurpm::progress($new_stage);
        }
    };

    my @base = ("basesystem", split /,\s*/, $urpm->{global_config}{'prohibit-remove'});
    my (%base, %basepackages);
    my $db = $db;
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
    Rpmdrake::gurpm::label(N("Please wait, finding installed packages..."));
    Rpmdrake::gurpm::progress($level = 0.33);
    $reset_update->(0.66);
    my %installed_pkgs;
    $db->traverse(sub {
	    my ($pkg) = @_;
	    $update->();
	    my $fullname = urpm_name($pkg);
	    #- Extract summary and description since they'll be lost when the header is packed
	    $installed_pkgs{$fullname} = {
		selected => 0, pkg => $pkg, urpm_name => urpm_name($pkg),
		summary => rpm_summary($pkg->summary),
		description => rpm_description($pkg->description),
	    } if !($installed_pkgs{$fullname} && $installed_pkgs{$fullname}{description});
	    if (my $name = $base{$fullname}) {
		$installed_pkgs{$fullname}{base} = \$name;
		$pkg->set_flag_base(1) if $$name == 1;
	    }
	    $pkg->pack_header; # needed in order to call methods on objects outside ->traverse
	});
    my $group;
    if ($::options{parallel} && (($group) = @{$::options{parallel}})) {
        urpm::media::configure($urpm, parallel => $group);
    }

    # find out availlable packages:

    #$urpm = urpm->new;
    $urpm->{state} = {};
    my %installable_pkgs;
    my %updates;

    Rpmdrake::gurpm::label(N("Please wait, finding available packages..."));
    Rpmdrake::gurpm::progress($level = 0.66);

    @update_medias = grep { !$_->{ignore} && $_->{update} } @{$urpm->{media}};
    check_update_media_version($urpm, @update_medias);

    my $requested = {};
    my $state = {};
    $urpm->request_packages_to_upgrade(
	$db,
	$state,
	$requested,
	start => 0,
	end   => $#{$urpm->{depslist}},
    );
    $urpm->compute_installed_flags($db); # TODO/FIXME: not for updates
    $urpm->{depslist}[$_]->set_flag_installed foreach keys %$requested; #- pretend it's installed
    $urpm->{rpmdrake_state} = $state; #- Don't forget it
    Rpmdrake::gurpm::progress($level = 0.7);

    my %pkg_sel   = map { $_ => 1 } @{$::options{'pkg-sel'}   || []};
    my %pkg_nosel = map { $_ => 1 } @{$::options{'pkg-nosel'} || []};
    my @updates_media_names = map { $_->{name} } @update_medias;
    $reset_update->(1);
    foreach my $pkg (@{$urpm->{depslist}}) {
        $update->();
	$pkg->flag_upgrade or next;
        my $selected = 0;

	if (member(pkg2medium($pkg, $urpm)->{name}, @updates_media_names) && $pkg->flag_installed) { # TODO/FIXME: for updates
            any { $pkg->id >= $_->{start} && $pkg->id <= $_->{end} } @update_medias or next;
            if ($::options{'pkg-sel'} || $::options{'pkg-nosel'}) {
		my $n = urpm_name($pkg);
		$pkg_sel{$n} || $pkg_nosel{$n} or next;
		$pkg_sel{$n} and $selected = 1;
	    } else {
             # selecting updates by default:
             $selected = 1;
	    }
	$updates{urpm_name($pkg)} = { selected => $selected, pkg => $pkg };
	} else {
	$installable_pkgs{urpm_name($pkg)} = { selected => $selected, pkg => $pkg };
     }
    }
    if ($::options{'pkg-sel'} && $::options{'pkg-nosel'}) {
        push @{$::options{'pkg-nosel'}}, @{$::options{'pkg-sel'}};
        delete $::options{'pkg-sel'};
    }

    $_->{pkg}->set_flag_installed foreach values %installed_pkgs;

    +{ urpm => $urpm,
       installed => \%installed_pkgs,
       installable => \%installable_pkgs,
       updates => \%updates,
       update_descr => \%update_descr,
   };
}


sub perform_installation {  #- (partially) duplicated from /usr/sbin/urpmi :-(
    my ($urpm, $pkgs) = @_;

    my $fatal_msg;
    my @error_msgs;
    my %Readmes;
    my $statusbar_msg_id;
    local $urpm->{fatal} = sub { printf STDERR "Fatal: %s\n", $_[1]; $fatal_msg = $_[1]; goto fatal_error };
    local $urpm->{error} = sub { printf STDERR "Error: %s\n", $_[0]; push @error_msgs, $_[0] };

    my $w = $::main_window;
    $w->set_sensitive(0);

    my $group;
    if ($::options{parallel} && (($group) = @{$::options{parallel}})) {
        my $pkgs = join(' ', map { if_($_->flag_requested, urpm_name($_)) } @{$urpm->{depslist}});
        system("urpmi -v --X --parallel $group $pkgs");
        if ($? == 0) {
            $statusbar_msg_id = statusbar_msg(
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
        open_db('force_sync');
        $w->set_sensitive(1);
        return 0;
    }

    my $_lock = urpm::lock::urpmi_db($urpm);
    my $_rpm_lock = urpm::lock::rpm_db($urpm, 'exclusive');
    my %pkgs = map { $_->id => undef } grep { $_->flag_selected } @{$urpm->{depslist}};
    my ($local_sources, $list, $local_to_removes) = urpm::get_pkgs::selected2list($urpm, 
	\%pkgs,
	clean_all => 1,
    );
    my $distant_number = scalar keys %pkgs;
    if (!$local_sources && (!$list || !@$list)) {
        interactive_msg(
	    N("Unable to get source packages."),
	    N("Unable to get source packages, sorry. %s",
		@error_msgs ? N("\n\nError(s) reported:\n%s", join("\n", @error_msgs)) : ''),
	    scroll => 1,
	);
        goto return_with_error;
    }
    foreach (@$local_to_removes) {
        unlink $_;
    }

    my @pkgs = map { scalar($_->fullname) } sort(grep { $_->flag_selected } @{$urpm->{depslist}});#{ $a->name cmp $b->name } @{$urpm->{depslist}}[keys %{$state->{selected}}];
    @{$urpm->{ask_remove}} = sort urpm::select::removed_packages($urpm, $urpm->{state});
    my @to_remove = grep { $_ } map { if_($pkgs->{$_}{selected}, $pkgs->{$_}{urpm_name}) } keys %$pkgs;

    my $r = join "\n", urpm::select::translate_why_removed($urpm, $urpm->{state}, @to_remove);

    my $install_count = int(@pkgs);
    my $to_install = $install_count ? 
      #-PO: in singular form, we use %2\$
      P("To satisfy dependencies, the following package is going to be installed:\n%2\$s\n", "To satisfy dependencies, the following %d packages are going to be installed:\n%s\n", $install_count, $install_count,
      formatlistpkg(map { s!.*/!!; $_ } @pkgs)) : '';
    my $remove_count =  scalar(@to_remove);
    interactive_msg(($to_install ? N("Confirmation") : N("Some packages need to be removed")),
                     ($r ? 
                        (!$to_install ? join("\n\n", P("Remove one package?", "Remove %d packages?", $remove_count, $remove_count), $r) :
 P("The following package has to be removed for others to be upgraded:", "The following packages have to be removed for others to be upgraded:", $remove_count) . join("\n\n", $r, if_($to_install, $to_install)) . N("Is it ok to continue?"))
                          : $to_install),
                     scroll => 1,
                     yesno => 1) or do {
                         $w->set_sensitive(1);
                         return 'canceled';
                     };

    Rpmdrake::gurpm::init(1 ? N("Please wait") : N("Package installation..."), N("Initializing..."), transient => $::w->{real_window});
    my $distant_progress;
    my $canceled;
    my %sources = urpm::download_source_packages(
	$urpm,
	$local_sources,
	$list,
	force_local => 1, # removed in urpmi 4.8.7
	ask_for_medium => sub {
	    interactive_msg(
		N("Change medium"),
		N("Please insert the medium named \"%s\" on device [%s]", $_[0], $_[1]),
		yesno => 1, text => { no => N("Cancel"), yes => N("Ok") },
	    );
	},
	callback => sub {
	    my ($mode, $file, $percent) = @_;
	    if ($mode eq 'start') {
		Rpmdrake::gurpm::label(N("Downloading package `%s' (%s/%s)...",
			basename($file), ++$distant_progress, $distant_number));
		Rpmdrake::gurpm::validate_cancel(but(N("Cancel")), sub { $canceled = 1 });
	    } elsif ($mode eq 'progress') {
		Rpmdrake::gurpm::progress($percent/100);
	    } elsif ($mode eq 'end') {
		Rpmdrake::gurpm::progress(1);
		Rpmdrake::gurpm::invalidate_cancel();
	    }
	    $canceled and return 'canceled';
	},
    );
    $canceled and goto return_with_error;
    Rpmdrake::gurpm::invalidate_cancel_forever();

    my %sources_install = %{urpm::extract_packages_to_install($urpm, \%sources, $urpm->{rpmdrake_state}) || {}};
    my @rpms_install = grep { !/\.src\.rpm$/ } values %sources_install;
    my @rpms_upgrade = grep { !/\.src\.rpm$/ } values %sources;

    if (!$::options{'no-verify-rpm'}) {
        Rpmdrake::gurpm::label(N("Verifying package signatures..."));
        my $total = @rpms_install + @rpms_upgrade;
        my $progress;
	my @invalid_sources = urpm::signature::check($urpm,
	    \%sources_install, \%sources,
	    translate => 1, basename => 1,
	    callback => sub {
		Rpmdrake::gurpm::progress(++$progress/$total);
	    },
	);
        if (@invalid_sources) {
            local $::main_window = $Rpmdrake::gurpm::mainw->{real_window};
            interactive_msg(
		N("Warning"),
		N("The following packages have bad signatures:\n\n%s\n\nDo you want to continue installation?",
		join("\n", sort @invalid_sources)), yesno => 1, if_(@invalid_sources > 10, scroll => 1),
	    ) or goto return_with_error;
        }
    }

    my $_guard = before_leaving { urpm::removable::try_umounting_removables($urpm) };

    my $something_installed;
    if (@rpms_install || @rpms_upgrade || @to_remove) {
        if (my @missing = grep { m|^/| && ! -e $_ } @rpms_install, @rpms_upgrade) {
            interactive_msg(
		N("Installation failed"),
		N("Installation failed, some files are missing:\n%s\n\nYou may want to update your media database.",
		    join "\n", map { "    $_" } @missing) .
		    (@error_msgs ? N("\n\nError(s) reported:\n%s", join("\n", @error_msgs)) : ''),
		if_(@error_msgs > 1, scroll => 1),
	    );
            goto return_with_error;
        }
        my $progress_nb;
        my $total_nb = scalar grep { m|^/| } @rpms_install, @rpms_upgrade;
        my $callback_inst = sub {
            my ($urpm, $type, $id, $subtype, $amount, $total) = @_;
            my $pkg = defined $id ? $urpm->{depslist}[$id] : undef;
            if ($subtype eq 'start') {
                if ($type eq 'trans') {
                    Rpmdrake::gurpm::label(@rpms_install ? N("Preparing packages installation...") : N("Preparing..."));
                } elsif (defined $pkg) {
                    $something_installed = 1;
                    Rpmdrake::gurpm::label(N("Installing package `%s' (%s/%s)...", $pkg->name, ++$progress_nb, $total_nb));
                }
            } elsif ($subtype eq 'progress') {
                Rpmdrake::gurpm::progress($total ? $amount/$total : 1);
            }
        };
	my $fh;
        my @errors = urpm::install::install($urpm,
	    \@to_remove,
	    \%sources_install,
	    \%sources,
	    post_clean_cache => $urpm->{options}{'post-clean'},
	    callback_open => sub {
		my ($_data, $_type, $id) = @_;
		my $f = $sources_install{$id} || $sources{$id};
		open $fh, $f or $urpm->{error}(N("unable to access rpm file [%s]", $f));
		return fileno $fh;
	    },
	    callback_inst => $callback_inst,
	    callback_trans => $callback_inst,
	    callback_close => sub {
		my ($urpm, undef, $pkgid) = @_;
		return unless defined $pkgid;
		my $pkg = $urpm->{depslist}[$pkgid];
		my $fullname = $pkg->fullname;
		my $trtype = (any { /\Q$fullname/ } values %sources_install) ? 'install' : '(update|upgrade)';
		foreach ($pkg->files) { /\bREADME(\.$trtype)?\.urpmi$/ and $Readmes{$_} = $fullname }
		close $fh;
	    },
	);
        Rpmdrake::gurpm::end();

        if (@errors || @error_msgs) {
            interactive_msg(
		N("Problem during installation"),
		N("There was a problem during the installation:\n\n%s",
		    join("\n", @errors, @error_msgs)),
		if_(@errors + @error_msgs > 1, scroll => 1),
	    );
            $w->set_sensitive(1);
            return !$something_installed;
        }

        my %pkg2rpmnew;
        foreach my $u (@rpms_upgrade) {
            $u =~ m|/([^/]+-[^-]+-[^-]+)\.[^\./]+\.rpm$|
              and $pkg2rpmnew{$1} = [ grep { m|^/etc| && (-r "$_.rpmnew" || -r "$_.rpmsave") }
                                      map { chomp_($_) } run_rpm("rpm -ql $1") ];
        }
	dialog_rpmnew(N("The installation is finished; everything was installed correctly.

Some configuration files were created as `.rpmnew' or `.rpmsave',
you may now inspect some in order to take actions:"),
	    %pkg2rpmnew)
	    and $statusbar_msg_id = statusbar_msg(N("All requested packages were installed successfully."));
	if (keys %Readmes) { #- display the README*.urpmi files
	    interactive_packtable(
		N("Upgrade information"),
		$w->{real_window},
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
    } else {
        Rpmdrake::gurpm::end();
        interactive_msg(N("Error"),
                         N("Unrecoverable error: no package found for installation, sorry."));
    }

    $w->set_sensitive(1);
    statusbar_msg_remove($statusbar_msg_id); #- XXX maybe remove this
    return !($something_installed || scalar(@to_remove));

  fatal_error:
    Rpmdrake::gurpm::end();
    interactive_msg(N("Installation failed"),
                     N("There was a problem during the installation:\n\n%s", $fatal_msg));
  return_with_error:
    Rpmdrake::gurpm::end();
    $w->set_sensitive(1);
    return 1;
}


# -=-=-=---=-=-=---=-=-=-- remove packages -=-=-=---=-=-=---=-=-=-

sub perform_removal {
    my ($urpm, $pkgs) = @_;
    my @toremove = map { if_($pkgs->{$_}{selected}, $pkgs->{$_}{urpm_name}) } keys %$pkgs;
    my @results;
    slow_func_statusbar(
	N("Please wait, removing packages..."),
	$::main_window->{real_window},
	sub {
	    @results = $::options{parallel}
		? urpm::parallel::remove($urpm, \@toremove)
		: urpm::install::install($urpm, \@toremove, {}, {});
	    open_db('force_sync');
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
