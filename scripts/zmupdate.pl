#!/usr/bin/perl -w
#
# ==========================================================================
#
# ZoneMinder Update Script, $Date$, $Revision$
# Copyright (C) 2003, 2004, 2005  Philip Coombes
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# ==========================================================================
#
# This script just checks what the most recent release of ZoneMinder is
# at the the moment. It will eventually be responsible for applying and
# configuring upgrades etc, including on the fly upgrades.
#
use strict;
use bytes;

# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================

use constant CHECK_INTERVAL => (1*24*60*60); # Interval between version checks
use constant VERBOSE => 0; # Whether to output more verbose debug

# ==========================================================================
#
# Don't change anything below here
#
# ==========================================================================

use ZoneMinder;
use POSIX;
use DBI;
use Getopt::Long;
use Data::Dumper;

use constant EVENT_PATH => ZM_PATH_WEB.'/'.ZM_DIR_EVENTS;
use constant UPDATE_LOG_FILE => ZM_PATH_LOGS.'/zmupdate.log';

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $check = 0;
my $rename = 0;
my $zone_fix = 0;
my $version = '';
my $db_user = ZM_DB_USER;
my $db_pass = ZM_DB_PASS;
sub Usage
{
    print( "
Usage: zmupdate.pl <-c,--check|-r,--rename|-z,--zone-fix|-v<version>,--version=<version> [-u<dbuser> -p<dbpass>]>
Parameters are :-
-c, --check                      - Check for updated versions of ZoneMinder
-r, --rename                     - Rename images from old 'capture-nnn.jpg' format to new 'nnn-capture.jpg' style from v1.17.2
-z, --zone-fix                   - Update zone percentage sizes from %ge of image to %ge of zone from 1.18.2 onwards
-v<version>, --version=<version> - Upgrade to the current version from <version>
-u<dbuser>, --user=<dbuser>      - Alternate DB user with privileges to alter DB
-p<dbpass>, --pass=<dbpass>      - Password of alternate DB user with privileges to alter DB
");
    exit( -1 );
}

if ( !GetOptions( 'check'=>\$check, 'rename'=>\$rename, 'zone-fix'=>\$zone_fix, 'version=s'=>\$version, 'user:s'=>\$db_user, 'pass:s'=>\$db_pass ) )
{
	Usage();
}

if ( ! ($check || $rename || $zone_fix || $version) )
{
	print( STDERR "Please give a valid option\n" );
	Usage();
}

if ( ($check + $rename + $zone_fix + ($version?1:0)) > 1 )
{
	print( STDERR "Please give only one option\n" );
	Usage();
}

if ( $check )
{
	open( LOG, '>>'.UPDATE_LOG_FILE ) or die( "Can't open log file: $!" );
	open( STDOUT, ">&LOG" ) || die( "Can't dup stdout: $!" );
	select( STDOUT ); $| = 1;
	open( STDERR, ">&LOG" ) || die( "Can't dup stderr: $!" );
	select( STDERR ); $| = 1;
	select( LOG ); $| = 1;
}

print( "Update agent starting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );

if ( $check && ZM_CHECK_FOR_UPDATES )
{
	my $dbh = DBI->connect( "DBI:mysql:database=".ZM_DB_NAME.";host=".ZM_DB_HOST, ZM_DB_USER, ZM_DB_PASS );

	my $curr_version = ZM_DYN_CURR_VERSION;
	my $last_version = ZM_DYN_LAST_VERSION;
	my $last_check = ZM_DYN_LAST_CHECK;

	if ( !$curr_version )
	{
		$curr_version = ZM_VERSION;

		my $sql = "update Config set Value = ? where Name = 'ZM_DYN_CURR_VERSION'";
		my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute( $curr_version ) or die( "Can't execute: ".$sth->errstr() );
	}

	$dbh->disconnect();
	while( 1 )
	{
		my $now = time();
		if ( !$last_version || !$last_check || (($now-$last_check) > CHECK_INTERVAL) )
		{
			print( "Checking for updates at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );

			use LWP::UserAgent;
			my $ua = LWP::UserAgent->new;
			$ua->agent( "ZoneMinder Update Agent/".ZM_VERSION );

			my $req = HTTP::Request->new( GET=>'http://www.zoneminder.com/version' );
			my $res = $ua->request($req);

			if ( $res->is_success )
			{
				$last_version = $res->content;
				chomp($last_version);
				$last_check = $now;

				print( "Got version: '".$last_version."'\n" );

				my $dbh = DBI->connect( "DBI:mysql:database=".ZM_DB_NAME.";host=".ZM_DB_HOST, ZM_DB_USER, ZM_DB_PASS );

				my $lv_sql = "update Config set Value = ? where Name = 'ZM_DYN_LAST_VERSION'";
				my $lv_sth = $dbh->prepare_cached( $lv_sql ) or die( "Can't prepare '$lv_sql': ".$dbh->errstr() );
				my $lv_res = $lv_sth->execute( $last_version ) or die( "Can't execute: ".$lv_sth->errstr() );

				my $lc_sql = "update Config set Value = ? where Name = 'ZM_DYN_LAST_CHECK'";
				my $lc_sth = $dbh->prepare_cached( $lc_sql ) or die( "Can't prepare '$lc_sql': ".$dbh->errstr() );
				my $lc_res = $lc_sth->execute( $last_check ) or die( "Can't execute: ".$lc_sth->errstr() );

				$dbh->disconnect();
			}
			else
			{
				print( "Error check failed: '".$res->status_line()."'\n" );
			}
		}
		sleep( 3600 );
	}
}
if ( $rename )
{
	require File::Find;

	chdir( EVENT_PATH );

	sub renameImage
	{
		my $file = $_;

		# Ignore directories
		if ( -d $file )
		{
			print( "Checking directory '$file'\n" );
			return;
		}
		if ( $file !~ /(capture|analyse)-(\d+)(\.jpg)/ )
		{
			return;
		}
		my $new_file = "$2-$1$3";

		print( "Renaming '$file' to '$new_file'\n" );
		rename( $file, $new_file ) or warn( "Can't rename '$file' to '$new_file'" );
	}

	File::Find::find( \&renameImage, '.' );
}
if ( $zone_fix )
{
	require DBI;

	my $dbh = DBI->connect( "DBI:mysql:database=".ZM_DB_NAME.";host=".ZM_DB_HOST, ZM_DB_USER, ZM_DB_PASS );

	my $sql = "select Z.*, M.Width as MonitorWidth, M.Height as MonitorHeight from Zones as Z inner join Monitors as M on Z.MonitorId = M.Id where Z.Units = 'Percent'";
	my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
	my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
	my @zones;
	while( my $zone = $sth->fetchrow_hashref() )
	{
		push( @zones, $zone );
	}
	$sth->finish();

	foreach my $zone ( @zones )
	{
		my $zone_width = (($zone->{HiX}*$zone->{MonitorWidth})-($zone->{LoX}*$zone->{MonitorWidth}))/100;
		my $zone_height = (($zone->{HiY}*$zone->{MonitorHeight})-($zone->{LoY}*$zone->{MonitorHeight}))/100;
		my $zone_area = $zone_width * $zone_height;
		my $monitor_area = $zone->{MonitorWidth} * $zone->{MonitorHeight};
		my $sql = "update Zones set MinAlarmPixels = ?, MaxAlarmPixels = ?, MinFilterPixels = ?, MaxFilterPixels = ?, MinBlobPixels = ?, MaxBlobPixels = ? where Id = ?";
		my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute(
			($zone->{MinAlarmPixels}*$monitor_area)/$zone_area,
			($zone->{MaxAlarmPixels}*$monitor_area)/$zone_area,
			($zone->{MinFilterPixels}*$monitor_area)/$zone_area,
			($zone->{MaxFilterPixels}*$monitor_area)/$zone_area,
			($zone->{MinBlobPixels}*$monitor_area)/$zone_area,
			($zone->{MaxBlobPixels}*$monitor_area)/$zone_area,
			$zone->{Id}
		) or die( "Can't execute: ".$sth->errstr() );
	}
}
if ( $version )
{
	my ( $detaint_version ) = $version =~ /^([\w.]+)$/;
	$version = $detaint_version;

	print( "\nInitiating database upgrade to version ".ZM_VERSION."\n" );
	print( "Please ensure that ZoneMinder is stopped on your system prior to upgrading the database.\nPress enter to continue or ctrl-C to stop : " );
	my $response = <STDIN>;

	if ( 0 )
	{
	print( "\nDo you wish to take a backup of your database prior to upgrading?\nThis may result in a large file if you have a lot of events.\nPress 'y' for a backup or 'n' to continue : " );

	$response = <STDIN>;
	chomp( $response );
	while ( $response !~ /^[yYnN]$/ )
	{
		print( "Please press 'y' for a backup or 'n' to continue only : " );
		$response = <STDIN>;
		chomp( $response );
	}

	if ( $response =~ /^[yY]$/ )
	{
		my $command = "mysqldump -h".ZM_DB_HOST;
		if ( $db_user )
		{
			$command .= " -u".$db_user;
			if ( $db_pass )
			{
				$command .= " -p".$db_pass;
			}
		}
		my $backup = ZM_DB_NAME."-".$version.".dump";
		$command .= " --add-drop-table --databases ".ZM_DB_NAME." > ".$backup;
		print( "Creating backup to $backup. This may take several minutes.\n" );
		print( "Executing '$command'\n" ) if ( VERBOSE );
		my $output = qx($command);
		my $status = $? >> 8;
		if ( $status || VERBOSE )
		{
				chomp( $output );
				print( "Output: $output\n" );
		}
		if ( $status )
		{
			die( "Command '$command' exited with status: $status\n" );
		}
		else
		{
			print( "Database successfully backed up to $backup, proceeding to upgrade.\n" );
		}
	}
	elsif ( $response !~ /^[nN]$/ )
	{
		die( "Unexpected response '$response'" );
	}
	}

	sub patchDB
	{
		my $dbh = shift;
		my $version = shift;

		my $command = "mysql -h".ZM_DB_HOST;
		if ( $db_user )
		{
			$command .= " -u".$db_user;
			if ( $db_pass )
			{
				$command .= " -p".$db_pass;
			}
		}
		$command .= " ".ZM_DB_NAME." < ".ZM_PATH_BUILD."/db/zmalter-".$version.".sql";

		print( "Executing '$command'\n" ) if ( VERBOSE );
		my $output = qx($command);
		my $status = $? >> 8;
		if ( $status || VERBOSE )
		{
				chomp( $output );
				print( "Output: $output\n" );
		}
		if ( $status )
		{
			die( "Command '$command' exited with status: $status\n" );
		}
		else
		{
			print( "\nDatabase successfully upgraded to version $version.\n" );
			my $sql = "update Config set Value = ? where Name = 'ZM_DYN_DB_VERSION'";
			my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
			my $res = $sth->execute( $version ) or die( "Can't execute: ".$sth->errstr() );
		}
	}

	if ( ZM_DYN_DB_VERSION && ZM_DYN_DB_VERSION ne $version )
	{
		# Nothing yet
	}

	print( "\nUpgrading database to version ".ZM_VERSION."\n" );

	my $dbh = DBI->connect( "DBI:mysql:database=".ZM_DB_NAME.";host=".ZM_DB_HOST, ZM_DB_USER, ZM_DB_PASS );

	my $cascade = undef;
	if ( $cascade || $version eq "1.19.0" )
	{
		# Patch the database
		patchDB( $dbh, "1.19.0" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.19.1" )
	{
		# Patch the database
		patchDB( $dbh, "1.19.1");
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.19.2" )
	{
		# Patch the database
		patchDB( $dbh, "1.19.2" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.19.3" )
	{
		# Patch the database
		patchDB( $dbh, "1.19.3" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.19.4" )
	{
		require DBI;

		# Rename the event directories and create a new symlink for the names
		chdir( EVENT_PATH );

		my $sql = "select * from Monitors order by Id";
		my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
		while( my $monitor = $sth->fetchrow_hashref() )
		{
			if ( -d $monitor->{Name} )
			{
				rename( $monitor->{Name}, $monitor->{Id} ) or warn( "Can't rename existing monitor directory '$monitor->{Name}' to '$monitor->{Id}': $!" );
				symlink( $monitor->{Id}, $monitor->{Name} ) or warn( "Can't symlink monitor directory '$monitor->{Id}' to '$monitor->{Name}': $!" );
			}
		}
		$sth->finish();
		
		# Patch the database
		patchDB( $dbh, "1.19.4" );

		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.19.5" )
	{
		print( "\nThis version now only uses one database user.\nPlease ensure you have run zmconfig.pl and re-entered your database username and password prior to upgrading, or the upgrade will fail.\nPress enter to continue or ctrl-C to stop : " );
		# Patch the database
		my $dummy = <STDIN>;
		patchDB( $dbh, "1.19.5" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.20.0" )
	{
		# Patch the database
		patchDB( $dbh, "1.20.0" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.20.1" )
	{
		# Patch the database
		patchDB( $dbh, "1.20.1" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.21.0" )
	{
		# Patch the database
		patchDB( $dbh, "1.21.0" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.21.1" )
	{
		# Patch the database
		patchDB( $dbh, "1.21.1" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.21.2" )
	{
		# Patch the database
		patchDB( $dbh, "1.21.2" );
		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.21.3" )
	{
		# Patch the database
		patchDB( $dbh, "1.21.3" );

		# Add appropriate widths and heights to events
		{
		print( "Updating events. This may take a few minutes. Please wait.\n" );
		my $sql = "select * from Monitors order by Id";
		my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
		while( my $monitor = $sth->fetchrow_hashref() )
		{
			my $sql = "update Events set Width = ?, Height = ? where MonitorId = ?";
			my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
			my $res = $sth->execute( $monitor->{Width}, $monitor->{Height}, $monitor->{Id} ) or die( "Can't execute: ".$sth->errstr() );
		}
		$sth->finish();
		}

		# Add sequence numbers
		{
			print( "Updating monitor sequences. Please wait.\n" );
			my $sql = "select * from Monitors order by Id";
			my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
			my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
			my $sequence = 1;
			while( my $monitor = $sth->fetchrow_hashref() )
			{
				my $sql = "update Monitors set Sequence = ? where Id = ?";
				my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
				my $res = $sth->execute( $sequence++, $monitor->{Id} ) or die( "Can't execute: ".$sth->errstr() );
			}
			$sth->finish();
		}

		# Update saved filters
		{
			print( "Updating saved filters. Please wait.\n" );
			my $sql = "select * from Filters";
			my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
			my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
			my @filters;
			while( my $filter = $sth->fetchrow_hashref() )
			{
				push( @filters, $filter );
			}
			$sth->finish();
			$sql = "update Filters set Query = ? where Name = ?";
			$sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
			foreach my $filter ( @filters )
			{
				if ( $filter->{Query} =~ /op\d=&/ )
				{
					( my $new_query = $filter->{Query} ) =~ s/(op\d=)&/$1=&/g;
					$res = $sth->execute( $new_query, $filter->{Name} ) or die( "Can't execute: ".$sth->errstr() );
				}
			}
		}

		$cascade = !undef;
	}
	if ( $cascade || $version eq "1.21.4" )
	{
		# Patch the database
		patchDB( $dbh, "1.21.4" );

		# Convert zones to new format
		{
			print( "Updating zones. Please wait.\n" );

			# Get the existing zones from the DB
			my $sql = "select Z.*,M.Width,M.Height from Zones as Z inner join Monitors as M on (Z.MonitorId = M.Id)";
			my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
			my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
			my @zones;
			while( my $zone = $sth->fetchrow_hashref() )
			{
				push( @zones, $zone );
			}
			$sth->finish();

			no strict 'refs';
			foreach my $zone ( @zones )
			{
				# Create the coordinate strings
				if ( $zone->{Units} eq "Pixels" )
				{
					my $sql = "update Zones set NumCoords = 4, Coords = concat( LoX,',',LoY,' ',HiX,',',LoY,' ',HiX,',',HiY,' ',LoX,',',HiY ), Area = round( ((HiX-LoX)+1)*((HiY-LoY)+1) ) where Id = ?"; 
					my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
					my $res = $sth->execute( $zone->{Id} ) or die( "Can't execute: ".$sth->errstr() );
				}
				else
				{
					my $lo_x = ($zone->{LoX} * ($zone->{Width}-1) ) / 100;
					my $hi_x = ($zone->{HiX} * ($zone->{Width}-1) ) / 100;
					my $lo_y = ($zone->{LoY} * ($zone->{Height}-1) ) / 100;
					my $hi_y = ($zone->{HiY} * ($zone->{Height}-1) ) / 100;
					my $area = (($hi_x-$lo_x)+1)*(($hi_y-$lo_y)+1);
					my $sql = "update Zones set NumCoords = 4, Coords = concat( round(?),',',round(?),' ',round(?),',',round(?),' ',round(?),',',round(?),' ',round(?),',',round(?) ), Area = round(?), MinAlarmPixels = round(?), MaxAlarmPixels = round(?), MinFilterPixels = round(?), MaxFilterPixels = round(?), MinBlobPixels = round(?), MaxBlobPixels = round(?) where Id = ?"; 
					my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
					my $res = $sth->execute( $lo_x, $lo_y, $hi_x, $lo_y, $hi_x, $hi_y, $lo_x, $hi_y, $area, ($zone->{MinAlarmPixels}*$area)/100, ($zone->{MaxAlarmPixels}*$area)/100, ($zone->{MinFilterPixels}*$area)/100, ($zone->{MaxFilterPixels}*$area)/100, ($zone->{MinBlobPixels}*$area)/100, ($zone->{MaxBlobPixels}*$area)/100, $zone->{Id} ) or die( "Can't execute: ".$sth->errstr() );
				}
			}
		}

		$cascade = !undef;
	}
	if ( !$cascade )
	{
		die( "Can't find upgrade from version '$version'" );
	}
	$dbh->disconnect();
	print( "\nDatabase upgrade to version ".ZM_VERSION." successful.\n" );
}
print( "Update agent exiting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );
exit();