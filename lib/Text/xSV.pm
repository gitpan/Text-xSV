package Text::xSV;
$VERSION = 0.06;
use strict;
use Carp;
use vars qw(%in_compute);

sub alias {
  my ($self, $from, $to) = @_;
  my $field_pos = $self->{field_pos}
    or confess("Can't call alias before headers are bound");
  unless (exists $field_pos->{$from}) {
    confess("'$from' is not available to alias");
  }
  $field_pos->{$to} = $field_pos->{$from};
}

sub add_compute {
  my ($self, $name, $compute) = @_;
  my $field_pos = $self->{field_pos}
    or confess("Can't call add_compute before headers are bound");
  unless (UNIVERSAL::isa($compute, "CODE")) {
    confess('Usage: $csv->add_compute("name", sub {FUNCTION});');
  }
  $field_pos->{$name} = $compute;
}

sub bind_fields {
  my $self = shift;
  my %field_pos;
  foreach my $i (0..$#_) {
    $field_pos{$_[$i]} = $i;
  }
  $self->{field_pos} = \%field_pos;
}

sub bind_header {
  my $self = shift;
  $self->bind_fields($self->get_row());
  delete $self->{row};
}

sub delete {
  my $self = shift;
  my $field_pos = $self->{field_pos}
    or confess("Can't call delete before headers are bound");
  foreach my $field (@_) {
    if (exists $field_pos->{$field}) {
      delete $field_pos->{$field};
    }
    else {
      confess("Cannot delete field '$field': it doesn't exist");
    }
  }
}

sub extract {
  my $self = shift;
  my $cached_results = $self->{cached} ||= {};
  my $row = $self->{row} or confess("No row found (did you call get_row())?");
  my $lookup = $self->{field_pos}
    or confess("Can't find field info (did you bind_fields or bind_header?)");
  my @data;
  foreach my $field (@_) {
    if (exists $lookup->{$field}) {
      my $position_or_compute = $lookup->{$field};
      if (not ref($position_or_compute)) {
        push @data, $row->[$position_or_compute];
      }
      elsif (exists $cached_results->{$field}) {
        push @data, $cached_results->{$field};
      }
      elsif (exists $in_compute{$field}) {
        confess("Infinite recursion detected in computing '$field'");
      }
      else {
        # Have to do compute
        local $in_compute{$field} = 1;
        $cached_results->{$field} = $position_or_compute->($self);
        push @data, $cached_results->{$field};
      }
    }
    else {
      my @allowed = sort keys %$lookup;
      confess(
        "Invalid field $field for file '$self->{filename}'.\n" .
        "Valid fields are: (@allowed)\n"
      );
    }
  }
  return wantarray ? @data : \@data;
}

sub get_fields {
  my $self = shift;
  my $field_pos = $self->{field_pos}
    or confess("Can't call get_fields before headers are bound");
  return keys %$field_pos;
}

# Private block for shared variables in a small "parse engine".
# The concept here is to use pos to step through a string.
# This is the real engine, all else is syntactic sugar.
{
  my ($self, $fh, $line);

  sub get_row {
    $self = shift;
    delete $self->{row};
    delete $self->{cached};
    $fh = $self->{fh};
    defined($line = <$fh>) or return;
    if (exists $self->{filter}) {
      $line = $self->{filter}->($line);
    }
    chomp($line);
    my @row = _get_row();
    if (not exists $self->{row_size}) {
      $self->{row_size} = @row;
    }
    elsif ($self->{row_size} != @row) {
      my $new = @row;
      my $where = "Line $., file $self->{filename}";
      carp( "$where had $new fields, expected $self->{row_size}" ); 
      $self->{row_size} = $new;
    }
    $self->{row} = \@row;
    return wantarray ? @row : [@row];
  }

  sub _get_row {
    my @row;
    my $q_sep = quotemeta($self->{sep});
    my $match_sep = qr/\G$q_sep/;
    my $start_field = qr/\G(")|\G([^"$q_sep]*)/;

    # This loop is the heart of the engine
    while ($line =~ /$start_field/g) {
      if ($1) {
        push @row, _get_quoted();
      }
      else {
        # Needed for Microsoft compatibility
        push @row, length($2) ? $2 : undef;
      }
      my $pos = pos($line);
      if ($line !~ /$match_sep/g) {
        if ($pos == length($line)) {
          return @row;
        }
        else {
          my $expected = "Expected '$self->{sep}'";
          confess("$expected at $self->{filename}, line $., char $pos");
        }
      }
    }
    confess("I have no idea how parsing $self->{filename} left me here!");
  }

  sub _get_quoted {
    my $piece = "";
    my $start_line = $.;
    my $start_pos = pos($line);
  
    while(1) {
      if ($line =~ /\G([^"]+)/gc) {
        # sequence of non-quote characters
        $piece .= $1;
      } elsif ($line =~ /\G""/gc) {
        # replace "" with "
        $piece .= '"';
      } elsif ($line =~ /\G"/g) {
        # closing quote
        return $piece;  # EXIT HERE
      }
      else {
        # Must be at end of line
        $piece .= $/;
        unless(defined($line = <$fh>)) {
          croak(
            "File $self->{filename} ended inside a quoted field\n"
              . "Field started at char $start_pos, line $start_line\n"
          );
        }
        if (exists $self->{filter}) {
          $line = $self->{filter}->($line);
        }
        chomp($line);
      }
    }
    confess("I have no idea how parsing $self->{filename} left me here!");
  }
}

sub new {
  my $self = bless ({'sep' => ","}, shift);
  my %allowed = map {($_, 1)} qw(filename fh filter sep);
  my %args = @_;
  foreach my $arg (keys %args) {
    unless (exists $allowed{$arg}) {
      my @allowed = sort keys %allowed;
      croak("Invalid argument '$arg', allowed args: (@allowed)");
    }
    $self->{$arg} = $args{$arg};
  }
  if (exists $self->{filename} and not exists $self->{fh}) {
    $self->open_file($self->{filename});
  }
  $self->set_sep($self->{sep});
  return $self;
}

sub open_file {
  my $self = shift;
  my $file = $self->{filename} = shift;
  my $fh = do {local *FH}; # Old trick, not needed in 5.6
  open ($fh, "< $file") or confess("Cannot read '$file': $!");
  $self->{fh} = $fh;
}


sub set_fh {
  $_[0]->{fh} = $_[1];
}

sub set_filename {
  $_[0]->{filename} = $_[1];
}

sub set_filter {
  $_[0]->{filter} = $_[1];
}

sub set_sep {
  my $self = shift;
  my $sep = shift;
  if (1 == length($sep)) {
    $self->{sep} = $sep;
  }
  else {
    confess("The separator '$sep' is not of length 1");
  }
}

1;

__END__

=head1 NAME

Text::xSV - read character separated files

=head1 SYNOPSIS

  use Text::xSV;
  my $csv = new Text::xSV;
  $csv->open_file("foo.csv");
  $csv->bind_header();
  # Make the headers case insensitive
  foreach my $field ($csv->get_fields) {
    if (lc($field) ne $field) {
      $csv->alias($field, lc($field));
    }
  }
  
  $csv->add_compute("message", sub {
    my $csv = shift;
    my ($name, $age) = $csv->extract(qw(name age));
    return "$name is $age years old\n";
  });

  while ($csv->get_row()) {
    my ($name, $age) = $csv->extract(qw(name age));
    print "$name is $age years old\n";
    # Same as
    #   print $csv->extract("message");
  }

=head1 DESCRIPTION

This module is for reading character separated data.  The most common
example is comma-separated.  However that is far from the only
possibility, the same basic format is exported by Microsoft products
using tabs, colons, or other characters.

The format is a series of rows separated by returns.  Within each row
you have a series of fields separated by your character separator.
Fields may either be unquoted, in which case they do not contain a
double-quote, separator, or return, or they are quoted, in which case
they may contain anything, and will encode double-quotes by pairing
them.  In Microsoft products, quoted fields are strings and unquoted
fields can be interpreted as being of various datatypes based on a
set of heuristics.  By and large this fact is irrelevant in Perl
because Perl is largely untyped.  The one exception that this module
handles that empty unquoted fields are treated as nulls which are
represented in Perl as undefined values.  If you want a zero-length
string, quote it.

People usually naively solve this with split.  A next step up is to
read a line and parse it.  Unfortunately this choice of interface
(which is made by Text::CSV on CPAN) makes it impossible to handle
returns embedded in a field.  Therefore you may need access to the
whole file.

This module solves the problem by creating a CSV object with access to
the filehandle, if in parsing it notices that a new line is needed, it
can read at will.

=head1 USAGE

First you set up and initialize an object, then you read the CSV file
through it.  The creation can also do multiple initializations as
well.  Here are the available methods

=over 4

=item C<new>

This is the constructor.  It takes a hash of optional arguments.
They are the I<filename> of the CSV file you are reading, the
I<fh> through which you read, an optional filter and the one
character I<sep> that you are using.  If the filename is passed
and the fh is not, then it will open a filehandle on that file
and sets the fh accordingly.  The separator defaults to a comma.
If the filter is present the lines will be passed through it
as they are read.  This is useful for stripping off \r, and
for stripping out things like Microsoft smart quotes at the
source.

=item C<set_filename>

=item C<set_fh>

=item C<set_filter>

=item C<set_sep>

Set methods corresponding to the optional arguments to C<new>.

=item C<open_file>

Takes the name of a file, opens it, then sets the filename and fh.

=item C<bind_fields>

Takes an array of fieldnames, memorizes the field positions for later
use.  C<bind_header> is preferred.

=item C<bind_header>

Reads a row from the file as a header line and memorizes the positions
of the fields for later use.  File formats that carry field information
tend to be far more robust than ones which do not, so this is the
preferred function.

=item C<get_row>

Reads a row from the file.  Returns an array or reference to an array
depending on context.  Will also store the row in the row property for
later access.

=item C<extract>

Extracts a list of fields out of the last row read.  In list context
returns the list, in scalar context returns an anonymous array.

=item C<alias>

Makes an existing field available under a new name.

  $csv->alias($old_name, $new_name);

=item C<get_fields>

Returns a list of all known fields in no particular order.

=item C<add_compute>

Adds an arbitrary compute.  A compute is an arbitrary anonymous
function.  When the computed field is extracted, Text::xSV will call
the compute in scalar context with the Text::xSV object as the only
argument.

Text::xSV caches results in case computes call other computes.  It
will also catch infinite recursion with a hopefully useful message.

=back

=head1 TODO

Allow blank fields at the end to be optionally undef?  (Requested by
Chad Simmons.)

Think through a writing interface.  (Suggested by dragonchild on
perlmonks.)

Add utility interfaces.  (Suggested by Ken Clark.)

Offer an option for working around the broken tab-delimited output
that some versions of Excel present for cut-and-paste.

=head1 BUGS

When I say single character separator, I mean it.

Performance could be better.  That is largely because the API was
chosen for simplicity of a "proof of concept", rather than for
performance.  One idea to speed it up you would be to provide an
API where you bind the requested fields once and then fetch many
times rather than binding the request for every row.

Also note that should you ever play around with the special variables
$`, $&, or $', you will find that it can get much, much slower.  The
cause of this problem is that Perl only calculates those if it has
ever seen one of those.  This does many, many matches and calculating
those is slow.

I need to find out what conversions are done by Microsoft products
that Perl won't do on the fly upon trying to use the values.

=head1 ACKNOWLEDGEMENTS

My thanks to people who have given me feedback on how they would like
to use this module, and particularly to Klaus Weidner for his patch
fixing a nasty segmentation fault from a stack overflow in the regular
expression engine on large fields.

=head1 AUTHOR AND COPYRIGHT

Ben Tilly (ben_tilly@operamail.com).  Originally posted at
http://www.perlmonks.org/node_id=65094.

Copyright 2001.  This may be modified and distributed on the same
terms as Perl.
