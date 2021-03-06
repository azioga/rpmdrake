#*****************************************************************************
# 
#  Copyright (c) 2002 Guillaume Cottenceau
#  Copyright (c) 2002-2007 Thierry Vignaud <tvignaud@mandriva.com>
#  Copyright (c) 2003, 2004, 2005 MandrakeSoft SA
#  Copyright (c) 2005, 2007 Mandriva SA
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

package rpmdrake;

use lib qw(/usr/lib/libDrakX);
use urpm::download ();
use urpm::prompt;
use urpm::media;

use MDK::Common;
use MDK::Common::System;
use urpm;
use urpm::cfg;
use URPM;
use URPM::Resolve;
use strict;
use c;
use POSIX qw(_exit);
use common;
use Locale::gettext;
use feature 'state';

our @ISA = qw(Exporter);
our $VERSION = '2.27';
our @EXPORT = qw(
    $changelog_first_config
    $compute_updates
    $filter
    $dont_show_selections
    $ignore_debug_media
    $mandrakeupdate_wanted_categories
    $mandrivaupdate_height
    $mandrivaupdate_width
    $max_info_in_descr
    $mode
    $NVR_searches
    $offered_to_add_sources
    $rpmdrake_height
    $rpmdrake_width
    $tree_flat
    $tree_mode
    $use_regexp
    $typical_width
    $clean_cache
    $auto_select
    $force_req_update
    $show_group_icons
    add_distrib_update_media
    add_medium_and_check
    but
    but_
    check_update_media_version
    choose_mirror
    distro_type
    fatal_msg
    getbanner
    get_icon
    interactive_list
    interactive_list_
    interactive_msg
    interactive_packtable
    myexit
    readconf
    remove_wait_msg
    run_drakbug
    show_urpm_progress
    slow_func
    slow_func_statusbar
    statusbar_msg
    statusbar_msg_remove
    update_sources
    update_sources_check
    update_sources_interactive
    update_sources_noninteractive
    wait_msg
    warn_for_network_need
    writeconf
);
our $typical_width = 280;

our $dont_show_selections;

# i18n: IMPORTANT: to get correct namespace (rpmdrake instead of libDrakX)
BEGIN { unshift @::textdomains, qw(rpmdrake urpmi rpm-summary-main rpm-summary-contrib rpm-summary-devel rpm-summary-non-free) }

use mygtk3 qw(gtknew);
use ugtk3 qw(:all);
ugtk3::add_icon_path('/usr/share/rpmdrake/icons');

Locale::gettext::bind_textdomain_codeset('rpmdrake', 'UTF8');

our $mandrake_release = cat_(
    -e '/etc/mandrakelinux-release' ? '/etc/mandrakelinux-release' : '/etc/release'
) || '';
chomp $mandrake_release;
our ($distro_version) = $mandrake_release =~ /(\d+\.\d+)/;
our ($branded, %distrib);
$branded = -f '/etc/sysconfig/oem'
    and %distrib = MDK::Common::System::distrib();
our $myname_update = $branded ? N("Software Update") : N("Online Update");

@rpmdrake::prompt::ISA = 'urpm::prompt';

sub rpmdrake::prompt::prompt {
    my ($self) = @_;
    my @answers;
    my $d = ugtk3->new("", grab => 1, if_($::main_window, transient => $::main_window));
    $d->{rwindow}->set_position('center_on_parent');
    gtkadd(
	$d->{window},
	gtkpack(
	    Gtk3::VBox->new(0, 5),
	    Gtk3::WrappedLabel->new($self->{title}),
	    (map { gtkpack(
		Gtk3::HBox->new(0, 5),
		Gtk3::Label->new($self->{prompts}[$_]),
		$answers[$_] = gtkset_visibility(gtkentry(), !$self->{hidden}[$_]),
	    ) } 0 .. $#{$self->{prompts}}),
	    gtksignal_connect(Gtk3::Button->new(N("Ok")), clicked => sub { Gtk3->main_quit }),
	),
    );
    $d->main;
    map { $_->get_text } @answers;
}

$urpm::download::PROMPT_PROXY = new rpmdrake::prompt(
    N("Please enter your credentials for accessing proxy\n"),
    [ N("User name:"), N("Password:") ],
    undef,
    [ 0, 1 ],
);

sub myexit {
    writeconf();
    ugtk3::exit(undef, @_);
}

my ($root) = grep { $_->[2] == 0 } list_passwd();
$ENV{HOME} = $> == 0 ? $root->[7] : $ENV{HOME} || '/root';
$ENV{HOME} = $::env if $::env = $Rpmdrake::init::rpmdrake_options{env}[0];

our $configfile = "$ENV{HOME}/.rpmdrake";

#
# Configuration File Options
#

# clear download cache after successful installation of packages
our $clean_cache;

# automatic select dependencies without user intervention
our $auto_select;

# try to update required packages
our $force_req_update;

our ($changelog_first_config, $compute_updates, $filter, $max_info_in_descr, $mode, $NVR_searches, $tree_flat, $tree_mode, $use_regexp, $show_group_icons);
our ($mandrakeupdate_wanted_categories, $ignore_debug_media, $offered_to_add_sources, $no_confirmation);
our ($rpmdrake_height, $rpmdrake_width, $mandrivaupdate_height, $mandrivaupdate_width);

our %config = (
    clean_cache => { 
	var => \$clean_cache, 
	default => [ 0 ] 
    },
    auto_select => { 
	var => \$auto_select, 
	default => [ 0 ] 
    },
    force_req_update => {
	var => \$force_req_update, 
	default => [ 1 ] 
    },
    changelog_first_config => { var => \$changelog_first_config, default => [ 0 ] },
    compute_updates => { var => \$compute_updates, default => [ 1 ] },
    dont_show_selections => { var => \$dont_show_selections, default => [ $> ? 1 : 0 ] },
    filter => { var => \$filter, default => [ 'all' ] },
    ignore_debug_media => { var => \$ignore_debug_media, default => [ 0 ] },
    mandrakeupdate_wanted_categories => { var => \$mandrakeupdate_wanted_categories, default => [ qw(security) ] },
    mandrivaupdate_height => { var => \$mandrivaupdate_height, default => [ 0 ] },
    mandrivaupdate_width => { var => \$mandrivaupdate_width, default => [ 0 ] },
    max_info_in_descr => { var => \$max_info_in_descr, default => [] },
    mode => { var => \$mode, default => [ 'by_group' ] },
    NVR_searches => { var => \$NVR_searches, default => [ 0 ] },
    'no-confirmation' => { var => \$no_confirmation, default => [ 0 ] },
    offered_to_add_sources => { var => \$offered_to_add_sources, default => [ 0 ] },
    rpmdrake_height => { var => \$rpmdrake_height, default => [ 0 ] },
    rpmdrake_width => { var => \$rpmdrake_width, default => [ 0 ] },
    tree_flat => { var => \$tree_flat, default => [ 0 ] },
    tree_mode => { var => \$tree_mode, default => [ qw(gui_pkgs) ] },
    use_regexp => { var => \$use_regexp, default => [ 0 ] },
    show_group_icons => { var => \$show_group_icons, default => [ 0 ] },
);

sub readconf() {
    ${$config{$_}{var}} = $config{$_}{default} foreach keys %config;
    foreach my $l (cat_($configfile)) {
	foreach (keys %config) {
	    ${$config{$_}{var}} = [ split ' ', $1 ] if $l =~ /^\Q$_\E(.*)/;
	}
    }
    # special cases:
    $::rpmdrake_options{'no-confirmation'} = $no_confirmation->[0] if !defined $::rpmdrake_options{'no-confirmation'};
    $Rpmdrake::init::default_list_mode = $tree_mode->[0] if ref $tree_mode && !$Rpmdrake::init::overriding_config;
}

sub writeconf() {
    return if $::env;
    unlink $configfile;

    # special case:
    $no_confirmation->[0] = $::rpmdrake_options{'no-confirmation'};

    output($configfile, map { "$_ " . (ref ${$config{$_}{var}} ? join(' ', @${$config{$_}{var}}) : undef) . "\n" } keys %config);
}

sub getbanner() {
    $::MODE or return undef;
    if (0) {
	+{
	remove  => N("Software Packages Removal"),
	update  => N("Software Packages Update"),
	install => N("Software Packages Installation"),
	};
    }
    Gtk3::Banner->new($ugtk3::wm_icon, $::MODE eq 'update' ? N("Software Packages Update") : N("Software Management"));
}

# return value:
# - undef if if closed (aka really canceled)
# - 0 if if No/Cancel
# - 1 if if Yes/Ok
sub interactive_msg {
    my ($title, $contents, %options) = @_;
    $options{transient} ||= $::main_window if $::main_window;
    local $::isEmbedded;
    my $d = ugtk3->new($title, grab => 1, if_(exists $options{transient}, transient => $options{transient}));
    $d->{rwindow}->set_position($options{transient} ? 'center_on_parent' : 'center_always');
    if ($options{scroll}) {
        $contents = ugtk3::markup_to_TextView_format($contents) if !ref $contents;
    } else { #- because we'll use a WrappedLabel
        $contents = formatAlaTeX($contents) if !ref $contents;
    }
    my $text_w;
    my $button_yes;
    gtkadd(
	$d->{window},
	gtkpack_(
	    Gtk3::VBox->new(0, 5),
	    1,
	    (
		$options{scroll} ?
            ($text_w = create_scrolled_window(gtktext_insert(Gtk3::TextView->new, $contents)))
              : ($text_w = gtknew('WrappedLabel', text_markup => $contents))
	    ),
         if_($options{widget}, 0, $options{widget}),
	    0,
	    gtkpack(
		create_hbox(),
		(
		    ref($options{yesno}) eq 'ARRAY' ? map {
			my $label = $_;
			gtksignal_connect(
			    $button_yes = Gtk3::Button->new($label),
			    clicked => sub { $d->{retval} = $label; Gtk3->main_quit }
			);
		    } @{$options{yesno}}
		    : (
			$options{yesno} ? (
			    gtksignal_connect( 
				Gtk3::Button->new($options{text}{no} || N("No")), 
				clicked => sub { $d->{retval} = 0; Gtk3->main_quit }
			    ),
			    gtksignal_connect(
				$button_yes = Gtk3::Button->new($options{text}{yes} || N("Yes")),
				clicked => sub { $d->{retval} = 1; Gtk3->main_quit }
			    ),
			)
			: gtksignal_connect(
			    $button_yes = Gtk3::Button->new(N("Ok")),
			    clicked => sub { Gtk3->main_quit }
			)
		    )
		)
	    )
	)
    );
    $d->{window}->set_focus($button_yes);
    $text_w->set_size_request($typical_width*2, $options{scroll} ? 300 : -1);
    $d->main;
    return $d->{retval};
}

sub interactive_packtable {
    my ($title, $parent_window, $top_label, $lines, $action_buttons) = @_;
    
    my $w = ugtk3->new($title, grab => 1, transient => $parent_window);
    local $::main_window = $w->{real_window};
    $w->{rwindow}->set_position($parent_window ? 'center_on_parent' : 'center');
    my $packtable = create_packtable({}, @$lines);

    gtkadd($w->{window},
	   gtkpack_(Gtk3::VBox->new(0, 5),
		    if_($top_label, 0, Gtk3::Label->new($top_label)),
		    1, create_scrolled_window($packtable),
		    0, gtkpack__(create_hbox(), @$action_buttons)));
    my $preq = $packtable->size_request;
    my ($xpreq, $ypreq) = ($preq->width, $preq->height);
    my $wreq = $w->{rwindow}->size_request;
    my ($xwreq, $ywreq) = ($wreq->width, $wreq->height);
    $w->{rwindow}->set_default_size(max($typical_width, min($typical_width*2.5, $xpreq+$xwreq)),
 				    max(200, min(450, $ypreq+$ywreq)));
    $w->main;
}

sub interactive_list {
    my ($title, $contents, $list, $callback, %options) = @_;
    my $d = ugtk3->new($title, grab => 1, if_(exists $options{transient}, transient => $options{transient}));
    $d->{rwindow}->set_position($options{transient} ? 'center_on_parent' : 'center_always');
    my @radios = gtkradio('', @$list);
    my $vbradios = $callback ? create_packtable(
	{},
	mapn {
	    my $n = $_[1];
	    [ $_[0],
	    gtksignal_connect(
		Gtk3::Button->new(but(N("Info..."))),
		clicked => sub { $callback->($n) },
	    ) ];
	} \@radios, $list,
    ) : gtkpack__(Gtk3::VBox->new(0, 0), @radios);
    my $choice;
    my $button_ok;
    gtkadd(
	$d->{window},
	gtkpack__(
	    Gtk3::VBox->new(0,5),
	    Gtk3::Label->new($contents),
	    int(@$list) > 8 ? gtkset_size_request(create_scrolled_window($vbradios), 250, 320) : $vbradios,
	    gtkpack__(
		create_hbox(),
          if_(!$options{nocancel},
          gtksignal_connect(
		    Gtk3::Button->new(N("Cancel")), clicked => sub { Gtk3->main_quit }),
          ),
          gtksignal_connect(
		    $button_ok=Gtk3::Button->new(N("Ok")), clicked => sub {
			each_index { $_->get_active and $choice = $::i } @radios;
			Gtk3->main_quit;
		    }
		)
	    )
	)
    );
    $d->{window}->set_focus($button_ok);
    $d->main;
    $choice;
}

sub interactive_list_ { interactive_list(@_, if_($::main_window, transient => $::main_window)) }

sub fatal_msg {
    interactive_msg @_;
    myexit -1;
}

sub wait_msg {
    my ($msg, %options) = @_;
    gtkflush();
    $options{transient} ||= $::main_window if $::main_window;
    local $::isEmbedded;
    my $mainw = ugtk3->new(N("Please wait"), grab => 1, if_(exists $options{transient}, transient => $options{transient}));
    $mainw->{real_window}->set_position($options{transient} ? 'center_on_parent' : 'center_always');
    my $label = ref($msg) =~ /^Gtk/ ? $msg : Gtk3::WrappedLabel->new($msg);
    gtkadd(
	$mainw->{window},
	gtkpack__(
	    gtkset_border_width(Gtk3::VBox->new(0, 5), 6),
	    $label,
	    if_(exists $options{widgets}, @{$options{widgets}}),
	)
    );
    $mainw->sync;
    gtkset_mousecursor_wait($mainw->{rwindow}->get_window) unless $options{no_wait_cursor};
    $mainw->flush;
    $mainw;
}

sub remove_wait_msg {
    my $w = shift;
    gtkset_mousecursor_normal($w->{rwindow}->get_window);
    $w->destroy;
}

sub but { "    $_[0]    " }
sub but_ { "        $_[0]        " }

sub slow_func ($&) {
    my ($param, $func) = @_;
    if (ref($param) =~ /^Gtk/) {
	gtkset_mousecursor_wait($param);
	ugtk3::flush();
	$func->();
	gtkset_mousecursor_normal($param);
    } else {
	my $w = wait_msg($param);
	$func->();
	remove_wait_msg($w);
    }
}

sub statusbar_msg {
    unless ($::statusbar) { #- fallback if no status bar
	if (defined &::wait_msg_) { goto &::wait_msg_ } else { goto &wait_msg }
    }
    my ($msg, $o_timeout) = @_;
    #- always use the same context description for now
    my $cx = $::statusbar->get_context_id("foo");
    $::w and $::w->{rwindow} and gtkset_mousecursor_wait($::w->{rwindow}->get_window);
    #- returns a msg_id to be passed optionnally to statusbar_msg_remove
    my $id = $::statusbar->push($cx, $msg);
    gtkflush();
    Glib::Timeout->add(5000, sub { statusbar_msg_remove($id); 0 }) if $o_timeout;
    $id;
}

sub statusbar_msg_remove {
    my ($msg_id) = @_;
    if (!$::statusbar || ref $msg_id) { #- fallback if no status bar
	goto &remove_wait_msg;
    }
    my $cx = $::statusbar->get_context_id("foo");
    if (defined $msg_id) {
	$::statusbar->remove($cx, $msg_id);
    } else {
	$::statusbar->pop($cx);
    }
    $::w and $::w->{rwindow} and gtkset_mousecursor_normal($::w->{rwindow}->get_window);
}

sub slow_func_statusbar ($$&) {
    my ($msg, $w, $func) = @_;
    gtkset_mousecursor_wait($w->get_window);
    my $msg_id = statusbar_msg($msg);
    gtkflush();
    $func->();
    statusbar_msg_remove($msg_id);
    gtkset_mousecursor_normal($w->get_window);
}

my %u2l = (
	   at => N_("Austria"),
	   au => N_("Australia"),
	   be => N_("Belgium"),
	   br => N_("Brazil"),
	   ca => N_("Canada"),
	   ch => N_("Switzerland"),
	   cr => N_("Costa Rica"),
	   cz => N_("Czech Republic"),
	   de => N_("Germany"),
	   dk => N_("Danmark"),
	   el => N_("Greece"),
	   es => N_("Spain"),
	   fi => N_("Finland"),
	   fr => N_("France"),
	   gr => N_("Greece"),
	   hu => N_("Hungary"),
	   il => N_("Israel"),
	   it => N_("Italy"),
	   jp => N_("Japan"),
	   ko => N_("Korea"),
	   nl => N_("Netherlands"),
	   no => N_("Norway"),
	   pl => N_("Poland"),
	   pt => N_("Portugal"),
	   ru => N_("Russia"),
	   se => N_("Sweden"),
	   sg => N_("Singapore"),
	   sk => N_("Slovakia"),
	   tw => N_("Taiwan"),
	   uk => N_("United Kingdom"),
	   cn => N_("China"),
	   com => N_("United States"),
	   org => N_("United States"),
	   net => N_("United States"),
	   edu => N_("United States"),
	  );
my $us = [ qw(com org net edu) ];
my %t2l = (
	   'America/\w+' =>       $us,
	   'Asia/Tel_Aviv' =>     [ qw(il ru it cz at de fr se) ],
	   'Asia/Tokyo' =>        [ qw(jp ko tw), @$us ],
	   'Asia/Seoul' =>        [ qw(ko jp tw), @$us ],
	   'Asia/Taipei' =>       [ qw(tw jp), @$us ],
	   'Asia/(Shanghai|Beijing)' => [ qw(cn tw sg), @$us ],
	   'Asia/Singapore' =>    [ qw(cn sg), @$us ],
	   'Atlantic/Reykjavik' => [ qw(uk no se fi dk), @$us, qw(nl de fr at cz it) ],
	   'Australia/\w+' =>     [ qw(au jp ko tw), @$us ],
	   'Brazil/\w+' =>        [ 'br', @$us ],
	   'Canada/\w+' =>        [ 'ca', @$us ],
	   'Europe/Amsterdam' =>  [ qw(nl be de at cz fr se dk it) ],
	   'Europe/Athens' =>     [ qw(gr pl cz de it nl at fr) ],
	   'Europe/Berlin' =>     [ qw(de be at nl cz it fr se) ],
	   'Europe/Brussels' =>   [ qw(be de nl fr cz at it se) ],
	   'Europe/Budapest' =>   [ qw(cz it at de fr nl se) ],
	   'Europe/Copenhagen' => [ qw(dk nl de be se at cz it) ],
	   'Europe/Dublin' =>     [ qw(uk fr be nl dk se cz it) ],
	   'Europe/Helsinki' =>   [ qw(fi se no nl be de fr at it) ],
	   'Europe/Istanbul' =>   [ qw(il ru it cz it at de fr nl se) ],
	   'Europe/Lisbon' =>     [ qw(pt es fr it cz at de se) ],
	   'Europe/London' =>     [ qw(uk fr be nl de at cz se it) ],
	   'Europe/Madrid' =>     [ qw(es fr pt it cz at de se) ],
	   'Europe/Moscow' =>     [ qw(ru de pl cz at se be fr it) ],
	   'Europe/Oslo' =>       [ qw(no se fi dk de be at cz it) ],
	   'Europe/Paris' =>      [ qw(fr be de at cz nl it se) ],
	   'Europe/Prague' =>     [ qw(cz it at de fr nl se) ],
	   'Europe/Rome' =>       [ qw(it fr cz de at nl se) ],
	   'Europe/Stockholm' =>  [ qw(se no dk fi nl de at cz fr it) ],
	   'Europe/Vienna' =>     [ qw(at de cz it fr nl se) ],
	  );

#- get distrib release number (2006.0, etc)
sub etc_version() {
    (my $v) = split / /, cat_('/etc/version');
    return $v;
}

#- returns the keyword describing the type of the distribution.
#- the parameter indicates whether we want base or update sources
sub distro_type {
    my ($want_base_distro) = @_;
    return 'cooker' if $mandrake_release =~ /cooker/i;
    #- we can't use updates for community while official is not out (release ends in ".0")
    if ($want_base_distro || $mandrake_release =~ /community/i && etc_version() =~ /\.0$/) {
	return 'official' if $mandrake_release =~ /official|limited/i;
	return 'community' if $mandrake_release =~ /community/i;
	#- unknown: fallback to updates
    }
    return 'updates';
}

sub compat_arch_for_updates($) {
    # FIXME: We prefer 64-bit packages to update on biarch platforms,
    # since the system is populated with 64-bit packages anyway.
    my ($arch) = @_;
    return $arch =~ /x86_64|amd64/ if arch() eq 'x86_64';
    MDK::Common::System::compat_arch($arch);
}

sub mirrors {
    my ($urpm, $want_base_distro) = @_;
    my $cachedir = $urpm->{cachedir} || '/root';
    require mirror;
    mirror::register_downloader(
        sub {
            my ($url) = @_;
            my $file = $url;
            $file =~ s!.*/!$cachedir/!;
            unlink $file;       # prevent "partial file" errors
            before_leaving(sub { unlink $file });

            my ($gurpm, $id, $canceled);
            # display a message in statusbar (if availlable):
            $::statusbar and $id = statusbar_msg(
                $branded
                  ? N("Please wait, downloading mirror addresses.")
                    : N("Please wait, downloading mirror addresses from the OpenMandriva website."),
                0);
            my $_clean_guard = before_leaving {
                undef $gurpm;
                $id and statusbar_msg_remove($id);
            };

            require Rpmdrake::gurpm;
            require Rpmdrake::pkg;

            my $res = urpm::download::sync_url($urpm, $url,
                                           dir => $cachedir,
                                           callback => sub {
                                               $gurpm ||= 
                                                 Rpmdrake::gurpm->new(N("Please wait"),
                                                                      transient => $::main_window);
                                               $canceled ||=
                                                 !Rpmdrake::pkg::download_callback($gurpm, @_);
                                               gtkflush();
                                           },
                                       );
            $res or die N("retrieval of [%s] failed", $file) . "\n";
            return $canceled ? () : cat_($file);
        });
    my @mirrors = @{ mirror::list(common::parse_LDAP_namespace_structure(cat_('/etc/product.id')), 'distrib') || [] };
    require timezone;
    my $tz = ${timezone::read()}{timezone};
    foreach my $mirror (@mirrors) {
	    my $goodness;
	    each_index { $_ = $u2l{$_} || $_; $_ eq $mirror->{country} and $goodness ||= 100-$::i } (map { if_($tz =~ /^$_$/, @{$t2l{$_}}) } keys %t2l), @$us;
         $mirror->{goodness} = $goodness + rand();
         $mirror->{country} = translate($mirror->{country});
    }
    unless (-x '/usr/bin/rsync') {
	@mirrors = grep { $_->{url} !~ /^rsync:/ } @mirrors;
    }
    return sort { $b->{goodness} <=> $a->{goodness} } @mirrors;
}

sub warn_for_network_need {
    my ($message, %options) = @_;
    $message ||= 
$branded
? N("I need to access internet to get the mirror list.
Please check that your network is currently running.

Is it ok to continue?")
: N("I need to contact the OpenMandriva website to get the mirror list.
Please check that your network is currently running.

Is it ok to continue?");
    interactive_msg(N("Mirror choice"), $message, yesno => 1, %options) or return '';
}

sub choose_mirror {
    my ($urpm, %options) = @_;
    delete $options{message};
    my @transient_options = exists $options{transient} ? (transient => $options{transient}) : ();
    warn_for_network_need($options{message}, %options) or return;
    my @mirrors = eval { mirrors($urpm, $options{want_base_distro}) };
    my $error = $@;
    if ($error) {
        $error = "\n$error\n";
	interactive_msg(N("Error during download"),
($branded
? N("There was an error downloading the mirror list:

%s
The network, or the website, may be unavailable.
Please try again later.", $error)
: N("There was an error downloading the mirror list:

%s
The network, or the OpenMandriva website, may be unavailable.
Please try again later.", $error)), %options

	);
	return '';
    }

    !@mirrors and interactive_msg(N("No mirror"),
($branded
? N("I can't find any suitable mirror.")
: N("I can't find any suitable mirror.

There can be many reasons for this problem; the most frequent is
the case when the architecture of your processor is not supported
by OpenMandriva Lx.")), %options
    ), return '';

    my $w = ugtk3->new(N("Mirror choice"), grab => 1, @transient_options);
    $w->{rwindow}->set_position($options{transient} ? 'center_on_parent' : 'center_always');
    my $tree_model = Gtk3::TreeStore->new("Glib::String");
    my $tree = Gtk3::TreeView->new_with_model($tree_model);
    $tree->get_selection->set_mode('browse');
    $tree->append_column(Gtk3::TreeViewColumn->new_with_attributes('', Gtk3::CellRendererText->new, text => 0));
    $tree->set_headers_visible(0);

    gtkadd(
	$w->{window}, 
	gtkpack_(
	    Gtk3::VBox->new(0,5),
	    0, N("Please choose the desired mirror."),
	    1, create_scrolled_window($tree),
	    0, gtkpack(
		create_hbox('edge'),
		map {
		    my $retv = $_->[1];
		    gtksignal_connect(
			Gtk3::Button->new(but($_->[0])),
			clicked => sub {
			    if ($retv) {
				my ($model, $iter) = $tree->get_selection->get_selected;
				$model and $w->{retval} = { sel => $model->get($iter, 0) };
			    }
			    Gtk3->main_quit;
			},
		    );
		} [ N("Cancel"), 0 ], [ N("Ok"), 1 ]
	    ),
	)
    );
    my %roots;
    $tree_model->append_set($roots{$_->{country}} ||= $tree_model->append_set(undef, [ 0 => $_->{country} ]),
			    [ 0 => $_->{url} ]) foreach @mirrors;

    $w->{window}->set_size_request(500, 400);
    $w->{rwindow}->show_all;

    my $path = Gtk3::TreePath->new_first;
    $tree->expand_row($path, 0);
    $path->down;
    $tree->get_selection->select_path($path);

    $w->main && return grep { $w->{retval}{sel} eq $_->{url} } @mirrors;
}

sub show_urpm_progress {
    my ($label, $pb, $mode, $file, $percent, $total, $eta, $speed) = @_;
    $file =~ s|([^:]*://[^/:\@]*:)[^/:\@]*(\@.*)|$1xxxx$2|; #- if needed...
    state $medium;
    if ($mode eq 'copy') {
	$pb->set_fraction(0);
	$label->set_label(N("Copying file for medium `%s'...", $file));
    } elsif ($mode eq 'parse') {
	$pb->set_fraction(0);
	$label->set_label(N("Examining file of medium `%s'...", $file));
    } elsif ($mode eq 'retrieve') {
	$pb->set_fraction(0);
	$label->set_label(N("Examining remote file of medium `%s'...", $file));
        $medium = $file;
    } elsif ($mode eq 'done') {
	$pb->set_fraction(1.0);
	$label->set_label($label->get_label . N(" done."));
        $medium = undef;
    } elsif ($mode eq 'failed') {
	$pb->set_fraction(1.0);
	$label->set_label($label->get_label . N(" failed!"));
        $medium = undef;
    } else {
        # FIXME: we're displaying misplaced quotes such as "downloading `foobar from 'medium Main Updates'´"
        $file = $medium && length($file) < 40 ? #-PO: We're downloading the said file from the said medium
                                                 N("%s from medium %s", basename($file), $medium)
                                               : basename($file);
        if ($mode eq 'start') {
            $pb->set_fraction(0);
            $label->set_label(N("Starting download of `%s'...", $file));
        } elsif ($mode eq 'progress') {
            if (defined $total && defined $eta) {
                $pb->set_fraction($percent/100);
                $label->set_label(N("Download of `%s'\ntime to go:%s, speed:%s", $file, $eta, $speed));
            } else {
                $pb->set_fraction($percent/100);
                $label->set_label(N("Download of `%s'\nspeed:%s", $file, $speed));
            }
        }
    }
    Gtk3->main_iteration while Gtk3->events_pending;
}

sub update_sources {
    my ($urpm, %options) = @_;
    my $cancel = 0;
    my $w; my $label; $w = wait_msg(
	$label = Gtk3::Label->new(N("Please wait, updating media...")),
	no_wait_cursor => 1,
	widgets => [
	    my $pb = gtkset_size_request(Gtk3::ProgressBar->new, 300, -1),
	    gtkpack(
		create_hbox(),
		gtksignal_connect(
		    Gtk3::Button->new(N("Cancel")),
		    clicked => sub {
			$cancel = 1;
                        $urpm->{error}->(N("Canceled"));
			$w and $w->destroy;
		    },
		),
	    ),
	],
    );
    my @media; @media = @{$options{medialist}} if ref $options{medialist};
    my $outerfatal = $urpm->{fatal};
    local $urpm->{fatal} = sub { $w->destroy; $outerfatal->(@_) };
    urpm::media::update_those_media($urpm, [ urpm::media::select_media_by_name($urpm, \@media) ],
	%options, allow_failures => 1,
	callback => sub {
	    $cancel and goto cancel_update;
	    my ($type, $media) = @_;
	    return if $type !~ /^(?:start|progress|end)$/ && @media && !member($media, @media);
	    if ($type eq 'failed') {
		$urpm->{fatal}->(N("Error retrieving packages"),
N("It's impossible to retrieve the list of new packages from the media
`%s'. Either this update media is misconfigured, and in this case
you should use the Software Media Manager to remove it and re-add it in order
to reconfigure it, either it is currently unreachable and you should retry
later.",
    $media));
	    } else {
		show_urpm_progress($label, $pb, @_);
	    }
	},
    );
    $w->destroy;
  cancel_update:
}

sub update_sources_check {
    my ($urpm, $options, $error_msg, @media) = @_;
    my @error_msgs;
    local $urpm->{fatal} = sub { push @error_msgs, $_[1]; goto fatal_error };
    local $urpm->{error} = sub { push @error_msgs, $_[0] };
    update_sources($urpm, %$options, noclean => 1, medialist => \@media);
  fatal_error:
    if (@error_msgs) {
        interactive_msg(N("Error"), sprintf(translate($error_msg), join("\n", map { formatAlaTeX($_) } @error_msgs)), scroll => 1);
        return 0;
    }
    return 1;
}

sub update_sources_interactive {
    my ($urpm, %options) = @_;
    my $w = ugtk3->new(N("Update media"), grab => 1, center => 1, %options);
    $w->{rwindow}->set_position($options{transient} ? 'center_on_parent' : 'center_always');
    my @buttons;
    my @media = grep { ! $_->{ignore} } @{$urpm->{media}};
    unless (@media) {
        interactive_msg(N("Warning"), N("No active medium found. You must enable some media to be able to update them."));
	return 0;
    }
    gtkadd(
	$w->{window},
	gtkpack_(
	    0, Gtk3::VBox->new(0,5),
	    0, Gtk3::Label->new(N("Select the media you wish to update:")),
            1, gtknew('ScrolledWindow', height => 300, child =>
                     # FIXME: using a listview would be just better:
                     gtknew('VBox', spacing => 5, children_tight => [
                         @buttons = map {
                             Gtk3::CheckButton->new_with_label($_->{name});
                         } @media
                     ])
	    ),
	    0, Gtk3::HSeparator->new,
	    0, gtkpack(
		create_hbox(),
		gtksignal_connect(
		    Gtk3::Button->new(N("Cancel")),
		    clicked => sub { $w->{retval} = 0; Gtk3->main_quit },
		),
		gtksignal_connect(
		    Gtk3::Button->new(N("Select all")),
		    clicked => sub { $_->set_active(1) foreach @buttons },
		),
		gtksignal_connect(
		    Gtk3::Button->new(N("Update")),
		    clicked => sub {
			$w->{retval} = any { $_->get_active } @buttons;
			# list of media listed in the checkbox panel
			my @buttonmedia = grep { !$_->{ignore} } @{$urpm->{media}};
			@media = map_index { if_($_->get_active, $buttonmedia[$::i]{name}) } @buttons;
			Gtk3->main_quit;
		    },
		),
	    )
	)
    );
    if ($w->main) {
        return update_sources_noninteractive($urpm, \@media, %options);
    }
    return 0;
}

sub update_sources_noninteractive {
    my ($urpm, $media, %options) = @_;

        urpm::media::select_media($urpm, @$media);
        update_sources_check(
	    $urpm,
	    {},
	    N_("Unable to update medium; it will be automatically disabled.\n\nErrors:\n%s"),
	    @$media,
	);
	return 1;
}

sub add_medium_and_check {
    my ($urpm, $options) = splice @_, 0, 2;
    my @newnames = ($_[0]); #- names of added media
    my $fatal_msg;
    my @error_msgs;
    local $urpm->{fatal} = sub { printf STDERR "Fatal: %s\n", $_[1]; $fatal_msg = $_[1]; goto fatal_error };
    local $urpm->{error} = sub { printf STDERR "Error: %s\n", $_[0]; push @error_msgs, $_[0] };
    if ($options->{distrib}) {
	@newnames = urpm::media::add_distrib_media($urpm, @_);
    } else {
	urpm::media::add_medium($urpm, @_);
    }
    if (@error_msgs) {
        interactive_msg(
	    N("Error"),
	    N("Unable to add medium, errors reported:\n\n%s",
	    join("\n", map { formatAlaTeX($_) } @error_msgs)) . "\n\n" . N("Medium: ") . "$_[0] ($_[1])",
	    scroll => 1,
	);
        return 0;
    }

    foreach my $name (@newnames) {
	urpm::download::set_proxy_config($_, $options->{proxy}{$_}, $name) foreach keys %{$options->{proxy} || {}};
    }

    if (update_sources_check($urpm, $options, N_("Unable to add medium, errors reported:\n\n%s"), @newnames)) {
        urpm::media::write_config($urpm);
	$options->{proxy} and urpm::download::dump_proxy_config();
    } else {
	urpm::media::read_config($urpm, 0);
        return 0;
    }

    my %newnames; @newnames{@newnames} = ();
    if (any { exists $newnames{$_->{name}} } @{$urpm->{media}}) {
        return 1;
    } else {
        interactive_msg(N("Error"), N("Unable to create medium."));
        return 0;
    }

  fatal_error:
    interactive_msg(N("Failure when adding medium"),
                    N("There was a problem adding medium:\n\n%s", $fatal_msg));
    return 0;
}

#- Check whether the default update media (added by installation)
#- matches the current mdk version
sub check_update_media_version {
    my $urpm = shift;
    foreach (@_) {
	if ($_->{name} =~ /(\d+\.\d+).*\bftp\du\b/ && $1 ne $distro_version) {
	    interactive_msg(
		N("Warning"),
		$branded
		? N("Your medium `%s', used for updates, does not match the version of %s you're running (%s).
It will be disabled.",
		    $_->{name}, $distrib{system}, $distrib{product})
		: N("Your medium `%s', used for updates, does not match the version of OpenMandriva Lx you're running (%s).
It will be disabled.",
		    $_->{name}, $distro_version)
	    );
	    $_->{ignore} = 1;
	    urpm::media::write_config($urpm) if -w $urpm->{config};
	    return 0;
	}
    }
    1;
}

sub add_distrib_update_media {
    my ($urpm, $mirror, %options) = @_;
    #- ensure a unique medium name
    my $medium_name = $rpmdrake::mandrake_release =~ /(\d+\.\d+) \((\w+)\)/ ? $2 . $1 . '-' : 'distrib';
    my $initial_number = 1 + max map { $_->{name} =~ /\(\Q$medium_name\E(\d+)\b/ ? $1 : 0 } @{$urpm->{media}};
    add_medium_and_check(
        $urpm,
        { nolock => 1, distrib => 1 },
        $medium_name,
        ($mirror ? $mirror->{url} : (undef, mirrorlist => '$MIRRORLIST')),
        probe_with => 'synthesis', initial_number => $initial_number, %options, 
        usedistrib => 1,
    );
}

sub open_help {
    my ($mode) = @_;
    use run_program;
    run_program::raw({ detach => 1, as_user => 1 },  'drakhelp', '--id', $mode ?  "software-management-$mode" : 'software-management');
    my $_s = N("Help launched in background");
    statusbar_msg(N("The help window has been started, it should appear shortly on your desktop."), 1);
}

sub run_drakbug {
    my ($id) = @_;
    run_program::raw({ detach => 1, as_user => 1 }, 'drakbug', '--report', $id);
}

mygtk3::add_icon_path('/usr/share/mcc/themes/default/');
sub get_icon {
    my ($mcc_icon, $fallback_icon) = @_;
    my $icon = eval { mygtk3::_find_imgfile($mcc_icon) };
    $icon ||= eval { mygtk3::_find_imgfile($fallback_icon) };
    $icon;
}

1;
