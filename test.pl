# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..11\n"; }
END {print "not ok 1\n" unless $loaded;}
use Text::xSV;
$loaded = 1;
print "ok 1\n";

######################### End of black magic.

# Insert your test code below (better if it prints "ok 13"
# (correspondingly "not ok 13") depending on the success of chunk 13
# of the test code):

my $tests_done = 1;

my $csv = new Text::xSV(filename => "test.csv");
ok();

$csv->bind_header();
ok();

# With the first row test the mechanics...

# True while fetch row
$csv->get_row() ? ok() : not_ok();

my @results = $csv->extract("one", "two");
ok();

(("hello" eq $results[0] and "world" eq $results[1]))
  ? ok() : not_ok();

test_row(undef, undef);
test_row("hello", "world");
test_row("return\nhere","quotes\"here");
test_row("","");
# end of file
$csv->get_row() ? not_ok() : ok();

sub not_ok {
  print "not ";
  ok();
}

sub ok {
  $tests_done++;
  print "ok $tests_done\n";
}

# Takes two arrays by reference, sees that they match
sub test_arrays_match {
  my ($ary_1, $ary_2) = @_;
  if (@$ary_1 != @$ary_2) {
    not_ok();
    return;
  }
  foreach (0..$#$ary_1) {
    if (
      defined($ary_1->[$_]) != defined($ary_2->[$_])
        or $ary_1->[$_] ne $ary_2->[$_]
    ) {
      not_ok();
      return;
    }
  }
  ok();
}

sub test_row {
  unless ($csv->get_row()) {
    not_ok();
    return;
  } 
  test_arrays_match([@_], [$csv->extract("one", "two")]);
}
