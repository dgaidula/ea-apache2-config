#!/usr/local/cpanel/3rdparty/bin/perl

# Copyright (c) 2015, cPanel, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package ea_apache2_config::phpconf;

use strict;
use Cpanel::Imports;
use Try::Tiny;
use Cpanel::ConfigFiles::Apache        ();
use Cpanel::AdvConfig::apache::modules ();
use Cpanel::DataStore                  ();
use Cpanel::Notify                     ();
use Getopt::Long                       ();
use POSIX qw( :sys_wait_h );

sub debug {
    my $cfg = shift;
    my $t   = localtime;
    print "[$t] DEBUG: @_\n" if $cfg->{args}->{debug};
}

# TODO: Update code to use new Cpanel::WebServer::Supported::apache::make_handler() interface
sub is_handler_supported {
    my $handler   = shift;
    my $supported = 0;

    my %handler_map = (
        'suphp' => [q{mod_suphp}],
        'cgi'   => [ q{mod_cgi}, q{mod_cgid} ],
        'dso'   => [q{libphp5}],
    );

    my $modules = Cpanel::AdvConfig::apache::modules::get_supported_modules();
    for my $mod ( @{ $handler_map{$handler} } ) {
        $supported = 1 if $modules->{$mod};
    }

    return $supported;
}

sub send_notification {
    my ( $package, $language, $webserver, $missing_handler, $replacement_handler ) = @_;

    my %args = (
        class            => q{EasyApache::EA4_LangHandlerMissing},
        application      => q{universal_hook_phpconf},
        constructor_args => [
            package             => $package,
            language            => $language,
            webserver           => $webserver,
            missing_handler     => $missing_handler,
            replacement_handler => $replacement_handler
        ],
    );

    # No point in catching the failure since we can't do anything
    # about here anyways.
    try {
        my $class = Cpanel::Notify::notification_class(%args);
        waitpid( $class->{'_icontact_pid'}, WNOHANG );
    };

    return 1;
}

# Retrieves current PHP
sub get_php_config {
    my $argv = shift;

    my %cfg = ( packages => [], args => { dryrun => 0, debug => 0 } );

    Getopt::Long::Configure(qw( pass_through ));    # not sure if we're passed any args by the universal hooks plugin
    Getopt::Long::GetOptionsFromArray(
        $argv,
        dryrun => \$cfg{args}{dryrun},
        debug  => \$cfg{args}{debug},
    );

    my $apacheconf = Cpanel::ConfigFiles::Apache->new();

    eval {
        require Cpanel::ProgLang;
        require Cpanel::ProgLang::Conf;
    };

    # Need to use the old API, not new one
    if ($@) {
        $cfg{api}         = 'old';
        $cfg{apache_path} = $apacheconf->file_conf_php_conf();
        $cfg{cfg_path}    = $cfg{apache_path} . '.yaml';

        try {
            require Cpanel::Lang::PHP::Settings;

            my $php = Cpanel::Lang::PHP::Settings->new();
            $cfg{php}      = $php;
            $cfg{packages} = $php->php_get_installed_versions();
            $cfg{cfg_ref}  = Cpanel::DataStore::fetch_ref( $cfg{cfg_path} );
        };
    }
    else {
        # get basic information in %cfg in case php isn't installed
        my $prog = Cpanel::ProgLang::Conf->new( type => 'php' );
        $cfg{api}         = 'new';
        $cfg{apache_path} = $apacheconf->file_conf_php_conf();    # hack until we can add this API to Cpanel::WebServer
        $cfg{cfg_path}    = $prog->get_file_path();

        try {
            my $php = Cpanel::ProgLang->new( type => 'php' );     # this will die if PHP isn't installed

            $cfg{php}      = $php;
            $cfg{packages} = $php->get_installed_packages();
            $cfg{cfg_ref}  = $prog->get_conf();
        };
    }

    return \%cfg;
}

sub get_rebuild_settings {
    my $cfg = shift;
    my $ref = $cfg->{cfg_ref};
    my %settings;

    return {} unless @{ $cfg->{packages} };

    my $php = $cfg->{php};

    # We can't assume that suphp will always be available for each package.
    # This will iterate over each package and verify that the handler is
    # installed.  If it's not, then revert to the 'cgi' handler, which
    # is installed by default.

    for my $package ( @{ $cfg->{packages} } ) {
        my $old_handler = $ref->{$package} || '';
        my $new_handler = is_handler_supported($old_handler) ? $old_handler : ( is_handler_supported('suphp') ? 'suphp' : 'cgi' );    # prefer suphp if no handler defined

        if ( $old_handler ne $new_handler ) {
            print locale->maketext(q{WARNING: You removed a configured [asis,Apache] handler.}), "\n";
            print locale->maketext( q{The “[_1]” package will revert to the “[_2]”[comment,the web server handler that will be used in its place (e.g. cgi)] “[_3]” handler.}, $package, 'Apache', $new_handler ), "\n";
            $cfg->{args}->{dryrun} && send_notification( $package, 'PHP', 'Apache', $old_handler, $new_handler );
        }

        $settings{$package} = $new_handler;
    }

    # Let's make sure that the system default version is still actually
    # installed.  If not, we'll try to set the highest-numbered version
    # that we have.  We are guaranteed to have at least one installed
    # version at this point in the script.
    #
    # It is possible that the system default setting may not match what we
    # got from the YAML file, so let's make sure things are as we expect.
    # System default will take precedence.
    if ( $cfg->{api} eq 'old' ) {
        my $sys_default = eval { $php->php_get_system_default_version() };
        my @packages = reverse sort @{ $cfg->{packages} };
        $sys_default = $packages[0] if ( !defined $sys_default || !grep( /\A\Q$sys_default\E\z/, @packages ) );
        $settings{phpversion} = $sys_default;
    }
    else {
        my $sys_default = $php->get_system_default_package();
        my @packages    = reverse sort @{ $cfg->{packages} };
        $sys_default = $packages[0] if ( !defined $sys_default || !grep( /\A\Q$sys_default\E\z/, @packages ) );
        $settings{default} = $sys_default;
    }

    return \%settings;
}

sub apply_rebuild_settings {
    my $cfg      = shift;
    my $settings = shift;

    if ( $#{ $cfg->{packages} } == -1 ) {
        debug( $cfg, "No PHP packages installed.  Removing configuration files." );
        !$cfg->{args}->{dryrun} && unlink( $cfg->{apache_path}, $cfg->{cfg_path} );
        return 1;
    }

    try {
        if ( $cfg->{api} eq 'old' ) {
            my %rebuild = %$settings;
            $rebuild{restart} = 0;
            $rebuild{dryrun}  = 0;
            $rebuild{version} = $settings->{phpversion};
            debug( $cfg, "Updating PHP using old API" );
            !$cfg->{args}->{dryrun} && $cfg->{php}->php_set_system_default_version(%rebuild);
        }
        else {
            my %pkginfo = %$settings;
            my $default = delete $pkginfo{default};

            debug( $cfg, "Setting the system default PHP package to the '$default' handler" );
            !$cfg->{args}->{dryrun} && $cfg->{php}->set_system_default_package( package => $default );
            debug( $cfg, "Successfully updated the system default PHP package" );

            require Cpanel::WebServer;
            my $apache = Cpanel::WebServer->new->get_server( type => "apache" );
            while ( my ( $pkg, $handler ) = each(%pkginfo) ) {
                debug( $cfg, "Setting the '$pkg' package to the '$handler' handler" );
                !$cfg->{args}->{dryrun} && $apache->set_package_handler(
                    type    => $handler,
                    lang    => $cfg->{php},
                    package => $pkg,
                );
                debug( $cfg, "Successfully updated the '$pkg' package" );
            }
        }
    }
    catch {
        logger->die("$_");    # copy $_ since it can be magical
    };

    return 1;
}

unless ( caller() ) {
    my $cfg      = get_php_config( \@ARGV );
    my $settings = get_rebuild_settings($cfg);
    apply_rebuild_settings( $cfg, $settings );
}

1;
