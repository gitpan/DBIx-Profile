#
# Version: 0.20
# Jeff Lathan
# Kerry Clendinning
# Deja.com, 1999
#

#  Copyright (c) 1999 Jeff Lathan, Kerry Clendinning.  All rights reserved. 
#  This program is free software; you can redistribute it and/or modify it 
#  under the same terms as Perl itself.

# .15 First public release.  Bad naming.
# .20 Fixed naming problems
#

#
# This package provides an easy way to profile your DBI-based application.
# By just including the package instead of DBI, and changing your database
# connect call, you will enable counting and measuring realtime and cpu
# time for each and every query used in the application.  The times are
# accumulated by phase: execute vs. fetch, and broken down by first fetch,
# subsequent fetch and failed fetch within each of the fetchrow_array,
# fetchrow_arrayref, and fetchrow_hashref methods.  More DBI functions will
# be added in the future.
# 
# USAGE:
# Add "use DBIx::Profile;"
# Replace "DBI->connect" with "DBIx::Profile->connect"
# Add "DBIx::Profile->init_rootclass;" before connect call
# Add a call to $dbh->printProfile() before calling disconnect,
#    or disconnect will dump the information.
#
# To Do:
#    Make the printProfile code "eleganter" (I know, its not a word :-)
#    Reduce the amount of code that needs to be inserted into the code
#       code to be profiled
#    Test with other packages.  The class will be less useful if it does
#       not work with other modules (such as Apache, etc).
#    

##########################################################################
##########################################################################

=head1 NAME

  DBIx::Profile - DBI query profiler

  Copyright (c) 1999 Jeff Lathan, Kerry Clendinning.  
  All rights reserved. 

  This program is free software; you can redistribute it and/or modify it 
  under the same terms as Perl itself.

=head1 SYNOPSIS

  use DBIx::Profile;
  $dbh = DBIx::Profile->connect(blah...blah);
  $dbh->printProfile();
  $dbh->disconnect(); 

=head1 DESCRIPTION

  DBIx::Profile is a quick and easy, and mostly transparent, profiler
  for scripts using DBI.  It collects information on the query 
  level, and keeps track of first, failed, normal, and total amounts
  (count, wall clock, cput time) for each function on the query.

  Not all DBI methods are profiled at this time.
  Except for replacing the existing "use" and "connect" statements,
  DBIx::Profile allows DBI functions to be called as usual on handles.

=head1 RECIPE

  1) Add "use DBIx::Profile"
  2) Change connects from "DBI->connect" to "DBIx::Profile->connect"
  3) Add "DBIx::Profile->init_rootclass;" before the connect
  4) Optional: add $dbh->printProfile (will execute during 
     disconnect otherwise)
  5) Run code
  6) Data output will happen at printProfile or $dbh->disconnect;

=head1 METHODS

  printProfile
     $dbh->printProfile();

     Will print out the data collected.
     If this is not called before disconnect, disconnect will call
     printProfile.

  disconnect
     $dbh->disconnect();

     Calls printProfile if it has not yet been called.

=head1 AUTHORS

  Jeff Lathan, jlathan@deja.com
  Kerry Clendinning, kerry@deja.com

=head1 SEE ALSO

  perl(1).

=cut

#
# For CPAN and Makefile.PL
#
$VERSION = '0.20';

use DBI;

package DBIx::Profile;

use strict;
use vars qw(@ISA );

@ISA = qw(DBI);

sub connect {
    my $self = shift;

    my $result = $self->SUPER::connect(@_);

    if ($result ) {

	# set flag so we know if we have not printing profile data
	$result->{'private_profile'}->{'printProfileFlag'} = 0;
    }
    return ($result);
}

##########################################################################
##########################################################################

package DBIx::Profile::db;
use strict;
use vars qw(@ISA );

@ISA = qw( DBI::db );

# 
# insert our "hooks" to grab subsequent operations
# Objects that can reclassify themselves... *shudder*
#
sub prepare {

    my $self = shift;
    
    my $result = $self->SUPER::prepare(@_);

    if ($result) {
	$result->initRef();
    } 

    return ($result);

}

# 
# disconnect from the database
# If printProfile has not been called, call it.
#
sub disconnect {
    my $self = shift;

    if ( !$self->{'private_profile'}->{'printProfileFlag'}) {
	$self->printProfile;
    }

    return $self->SUPER::disconnect(@_);
}

#
# Print the data collected.
#
# JEFF - The printing is kinda ugly!
#

sub printProfile {

    my $self = shift;

    my $name;
    my $qry;
    my $money;
    my $type;
    no integer;

    #
    # Set that we HAVE printed the results
    #
    $self->{'private_profile'}->{'printProfileFlag'} = 1;

    print "\n\n";

    foreach $qry (sort keys %{$self->{'private_profile'}}) {

	if ( $qry eq "printProfileFlag" ) {
	    next;
	}

	print "=================================================================\n";
	
	print $qry . "\n";
	foreach $name ( sort keys %{$self->{'private_profile'}->{$qry}}) {

	    #
	    # Right now, this assumes that we only have wall clock, cpu
	    # and count.  Not generic, but what we want NOW
	    # 
	    
	    if ( $name eq "first" ) {
		next;
	    }

	    print "   $name ---------------------------------------\n";

	    foreach $type (sort keys %{$self->{'private_profile'}->{$qry}->{$name}}) {
		print "      $type\n";
		
		my ($count, $time, $ctime);
		$count = $self->{'private_profile'}->{$qry}->{$name}->{$type}->{'count'};
		$time = $self->{'private_profile'}->{$qry}->{$name}->{$type}->{'realtime'};
		$ctime = $self->{'private_profile'}->{$qry}->{$name}->{$type}->{'cputime'};
		
		printf "         Count        : %10d\n",$count;
		printf "         Wall Clock   : %10.7f s   %10.7f s\n",$time,$time/$count;
		printf "         Cpu Time     : %10.7f s   %10.7f s\n",$ctime,$ctime/$count;
		
	    }
	}
    }
}

##########################################################################
##########################################################################

package DBIx::Profile::st;
use strict;
use vars qw(@ISA);

@ISA = qw(DBI::st);

#
# Get some accurancy for wall clock time
# Cpu time is still very coarse, but...
#
use Time::HiRes qw ( gettimeofday tv_interval);

#
# Aaron Lee (aaron@pointx.org) provided the majority of
# BEGIN block below.  It allowed the removal of a lot of duplicate code
# and makes the code much much cleaner, and easier
# to add DBI functionality.
#



BEGIN {

    # Basic idea for each timing function:
    # Grab timing info
    # Call real DBI call
    # Grab timing info
    # Calculate time diff
    # 

    # Wow, this is ugly!
    # To make it truly usable, it has to know whether or not we want
    # to return an array or not.  I apologize for the ugliness - jeff
    #
    # Just add more functions in here.  
    #
    my @func_list = ('fetchrow_array','fetchrow_arrayref','execute', 'fetchrow_hashref');
    
    my $func;

    foreach $func (@func_list){
	
	# define subroutine code, incl dynamic name and SUPER:: call 
	my $sub_code = 
	    "sub $func {" . '
		my $self = shift;
		my @result; 
                my $result;
		my ($time, $ctime, $temp, $x, $y, $z, $type);

                if (wantarray) {

                   $time = [gettimeofday];
		   ($ctime, $x ) = times();

                   @result =  $self->SUPER::' . "$func" . '(@_); 
	
		   ($y, $z ) = times();
		   $time = tv_interval ($time, [gettimeofday]);

                   #
                   # Checking scalar because we are also interested
                   # in catch an empty list
                   #
                   if (scalar @result) {
                      $type = "normal";
                   } else {
                      if (!$self->err) {
                         $type = "no more rows";
                      } else {
                         $type = "error";
                      }
                   }

		   $ctime = ($y + $z) - ($x + $ctime);
                   $self->increment($func,$type,$time, $ctime);
                   return @result;

                } else {

		   $time = [gettimeofday];
		   ($ctime, $x ) = times();

                   $result =  $self->SUPER::' . "$func" . '(@_); 
	
		   ($y, $z ) = times();
		   $time = tv_interval ($time, [gettimeofday]);

                   if (defined $result) {
                      if ($result ne "0E0") {
                         $type = "normal";
                      } else {
                         $type = "returned 0E0";
                      }

                   } else {
                      if (!$self->err) {
                         $type = "no more rows";
                      } else {
                         $type = "error";
                      }
                   }

		   $ctime = ($y + $z) - ($x + $ctime);
                   $self->increment($func,$type,$time, $ctime);
                   return $result;

                } # end of if (wantarray);

	    } # end of function definition
        ';
	
	# define $func in current package
	eval $sub_code;
    }
}

sub fetchrow {
    my $self = shift;
    #
    # fetchrow is just an alias for fetchrow_array, so
    # send it that way
    #

    return $self->fetchrow_array(@_);
}

sub increment {
    my ($self, $name, $type, $time, $ctime) = @_;

    my $ref;

    my $qry = $self->{'Statement'};

    $ref = $self->{'private_profile'};

    if ( $name =~ /^execute/ ) {
	$ref->{"first"} = 1;
    }

    if ( ($name =~ /^fetch/) && ($ref->{'first'} == 1) ) {
	$type = "first";
	$ref->{'first'} = 0;
    }

    $ref->{$name}->{$type}->{'count'}++;
    $ref->{$name}->{$type}->{'realtime'}+= $time;
    $ref->{$name}->{$type}->{'cputime'}+= $ctime;

    # "Total" instead of "total" so that it comes first in the list

    $ref->{$name}->{"Total"}->{'count'}++;
    $ref->{$name}->{"Total"}->{'realtime'}+= $time;
    $ref->{$name}->{"Total"}->{'cputime'}+= $ctime;
    
}

# 
# initRef is called from Prepare in DBIProfile
#
# Its purpose is to create the DBI's private_profile info
# so that we do not lose DBI::errstr in increment() on down the road
#
sub initRef {
    my $self = shift;
    my $qry = $self->{'Statement'};

    if (!exists($self->{'private_profile'})) {
	if (!exists($self->{'Database'}->{'private_profile'}->{$qry})) {
	    $self->{'Database'}->{'private_profile'}->{$qry} = {};
        }
        $self->{'private_profile'} = $self->{'Database'}->{'private_profile'}->{$qry};    
    }
}

1;


