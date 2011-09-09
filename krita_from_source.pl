#!/usr/bin/perl

#-----------------------------------------------------------------------------#
# Copyright (c) 2011 Kirk Kimmel. All rights reserved.
# This program is free software; you can redistribute it and/or modify it
# under the GPL v3 license. See LICENSE.txt.
#
# The newest version of this file can be found at:
#   https://github.com/kimmel/krita-from-source
#-----------------------------------------------------------------------------#

use v5.12;
use warnings;
use strict;
use English qw( -no_match_vars );
use Getopt::Long qw( GetOptions );
use Pod::Usage qw( pod2usage );
use Archive::Extract;
use POSIX qw( strftime );

use IO::CaptureOutput qw( qxx );
use File::Which qw( which );
use File::Find::Rule;

package main;

sub _ubuntu_notes {
    print <<'UBUNTU';
WARNING: Ubuntu 11.04 (and distros based on it) are currently known to have
problems when using a Wacom (no pressure, strange lines drawn). There are
workarounds for both issues. Please see:

https://bugs.launchpad.net/ubuntu/natty/+source/qt4-x11/+bug/762938
and 
https://bugs.launchpad.net/ubuntu/+source/xorg-server/+bug/799202

UBUNTU

    return;
}

sub detect_distro {
    my $source = '/etc/issue';
    if ( -r $source ) {
        open my $f, '<', $source or die "Opening file $source: $ERRNO\n";
        my $string = do { local ($RS); <$f> };
        close $f;

        given ($string) {
            when (m/ubuntu/ixms) { _ubuntu_notes(); return 'ubuntu'; }
            when (m/fedora/ixms) { return 'fedora'; }
            when (m/opensuse/ixms)  { return 'opensuse'; }
            when (m/mint[ ]11/ixms) { return 'mint_11'; }
            default {
                print "Your linux version is currently not supported.\n";
                exit 1;
            }
        }
    }
}

sub _install_deps {
    my $distro = shift;

    my %shared = (
        'ubuntu'   => 'apt-get -force-yes -yes ',
        'fedora'   => 'yum -y ',
        'opensuse' => 'zypper --non-interactive ',
        'mint_11'  => 'apt-get -force-yes -yes ',
    );

    my %remove = (
        'ubuntu'   => 'purge krita* koffice* karbon*',
        'fedora'   => 'remove koffice* calligra*',
        'opensuse' => 'remove koffice* calligra*',
    );

    my %deps = (
        'ubuntu' => 'install git wget && apt-get build-dep krita',
        'fedora' => 'install git wget gcc gcc-c++ && yum-builddep koffice',
        'opensuse' =>
            'install cmake gcc gcc-c++ libkde4-devel libeigen2-devel libexiv2-devel liblcms2-devel',
        'mint_11' =>
            'install cmake kdelibs5-dev zlib1g-dev libpng12-dev libboost-dev liblcms1-dev libeigen2-dev libexiv2-dev pstoedit libfreetype6-dev libglew1.5-dev libfftw3-dev libglib2.0-dev libopenexr-dev libtiff4-dev libjpeg62-dev',
    );

    print "Installing missing dependencies now.\n";

    #tools
    my @tools = split /[ ]+/, ( $shared{$distro} . 'install git wget' );
    my ( $stdout, $stderr, $success ) = qxx(@tools);
    print "\n$stdout\n $stderr\n";

    if ( $remove{$distro} ) {
        my @blockers = split /[ ]+/, ( $shared{$distro} . $remove{$distro} );
        ( $stdout, $stderr, $success ) = qxx(@blockers);
        print "\n$stdout\n $stderr\n";
    }

    #everything else
    my @deps = split /[ ]+/, ( $shared{$distro} . $deps{$distro} );
    ( $stdout, $stderr, $success ) = qxx(@deps);
    print "\n$stdout\n $stderr\n";

    return;
}

sub check_deps {
    my $distro = shift;
    if ( !which('wget') or !which('git') ) {
        if ( $EFFECTIVE_USER_ID != 0 ) {
            print "Error. Please run as root to install system software.\n";
            exit 1;
        }

        _install_deps($distro);
        exit 1;
    }
}

sub get_source_from_git {
    my $distro   = shift;
    my $git_repo = 'git://anongit.kde.org/calligra';
    my ( $stdout, $stderr );

    if ( -e 'calligra_src/.git/config' ) {
        chdir 'calligra_src/';
        print "Performing a git pull now. This may take a while.\n\n";
        ( $stdout, $stderr ) = qxx( 'git', 'pull' );
    }
    else {
        print
            "Performing a git clone since no existing git repo was found.\n",
            "This takes a long time depending on download times.\n\n";
        ( $stdout, $stderr ) = qxx( 'git', 'clone', $git_repo, 'calligra' );
    }

    return "###start git output###\n$stdout\n$stderr\n###end git output###\n";
}

sub _extract_tar_gz {
    my $file = shift;

    #this speeds up extraction
    $Archive::Extract::PREFER_BIN = 1;

    print "Extracting: $file\n";
    my $ae = Archive::Extract->new( archive => $file, type => 'tgz' );
    my $ok = $ae->extract() or die $ae->error;

    return;
}

sub get_source_tar_gz {
    my ( $stdout, $stderr );

    my $rule = File::Find::Rule->new;
    $rule->file;
    $rule->name(qr/calligra_.+_sha1-.+[.]tar[.]gz/);
    my @files = $rule->in('.');

    if (@files) {
        _extract_tar_gz( $files[0] );
        chdir './calligra/';
        ( $stdout, $stderr ) = qxx('./initrepo.sh');
        chdir '..';
    }
    else {
        print "Downloading calligra-latest.tar.gz\n";

        ( $stdout, $stderr )
            = qxx( 'wget',
            'http://anongit.kde.org/calligra/calligra-latest.tar.gz' );
        get_source_tar_gz();
        return;
    }
    print "###\n$stdout\n$stderr\n###\n";

    return;
}

sub _print_time {
    my $now_string = strftime "%Y-%m-%d %H:%M:%S", localtime;
    return "$now_string - ";
}

sub run {
    Getopt::Long::Configure('bundling');

    my $app_version = '1.0alpha';
    my $target_dir  = '/tmp/calligra';
    my $cli_options = GetOptions(
        'help|?' => sub { pod2usage( -verbose => 1 ) },
        'man'    => sub { pod2usage( -verbose => 2 ) },
        'usage'  => sub { pod2usage( -verbose => 0 ) },
        'version' => sub { print "version: $app_version\n"; exit 1; },
        'target-dir=s' => \$target_dir,
    ) or die "Incorrect usage.\n";

    my $my_distro = detect_distro();

    check_deps($my_distro);
    if ( $EFFECTIVE_USER_ID == 0 ) {
        print "Error. Action not permitted for user 'root'.\n";
        exit 2;
    }

    print _print_time, "Process started.\n\n";
    mkdir $target_dir;
    chdir $target_dir;

    get_source_tar_gz();

    #print get_source_from_git($my_distro);

    print _print_time, "Process completed.\n";

    return;
}

run() unless caller;

1;

__END__

#-----------------------------------------------------------------------------

=pod

=head1 NAME

C<krita_from_source> - Build krita from source.

=head1 VERSION

=head1 USAGE

  krita_from_source [ options ]
  
  krita_from_source [ --taget-dir ]
  
  krita_from_source { --help | --man | --usage | --version }

=head1 REQUIRED ARGUMENTS

=head1 ARGUMENTS

=head1 OPTIONS

  These are the application options.

=over

=item C<--target-dir>

  Set the target directory for the downloading.

=item C<--help>

  Displays a brief summary of options and exits.

=item C<--man>

  Displays the complete manual and exits.

=item C<--usage>

  Displays the basic application usage.

=item C<--version>

  Displays the version number and exits.

=back

=head1 DESCRIPTION

A script which automates the process of building krita from source without 
the hassle of having to chase dependencies and know complex command line-fu.

=head1 DIAGNOSTICS

=head1 EXIT STATUS

  0 - Sucessful program execution.
  1 - Program exited normally. --help, --man, and --version return 1.
  2 - Program exited normally. --usage returns 2.

=head1 CONFIGURATION

=head1 DEPENDENCIES

Perl version 5.12 or higher.
GNU Wget - The non-interactive network downloader.
git - the stupid content tracker

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

https://github.com/kimmel/krita-from-source/issues - File bugs here.

=head1 HOMEPAGE

https://github.com/kimmel/krita-from-source

=head1 AUTHOR

Kubuntutiac - A kde.org forum member who wrote the bash script this is 
based off of.
Kirk Kimmel - Author of this Perl script

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2011 < Kirk Kimmel >. All rights reserved.

This program is free software; you can redistribute it and/or modify it 
under the GPL v3 license. The full text of this license can be found online 
at < http://opensource.org/licenses/GPL-3.0 >

=cut

