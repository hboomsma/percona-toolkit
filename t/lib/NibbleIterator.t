#!/usr/bin/perl

BEGIN {
   die "The PERCONA_TOOLKIT_BRANCH environment variable is not set.\n"
      unless $ENV{PERCONA_TOOLKIT_BRANCH} && -d $ENV{PERCONA_TOOLKIT_BRANCH};
   unshift @INC, "$ENV{PERCONA_TOOLKIT_BRANCH}/lib";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More;

use Schema;
use SchemaIterator;
use Quoter;
use DSNParser;
use Sandbox;
use OptionParser;
use TableParser;
use TableNibbler;
use RowChecksum;
use NibbleIterator;
use PerconaTest;

use constant MKDEBUG => $ENV{MKDEBUG} || 0;

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

my $dp  = new DSNParser(opts=>$dsn_opts);
my $sb  = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $dbh = $sb->get_dbh_for('master');

if ( !$dbh ) {
   plan skip_all => 'Cannot connect to sandbox master';
}
else {
   plan tests => 21;
}

my $q  = new Quoter();
my $tp = new TableParser(Quoter=>$q);
my $nb = new TableNibbler(TableParser=>$tp, Quoter=>$q);
my $o  = new OptionParser(description => 'NibbleIterator');
my $rc = new RowChecksum(OptionParser => $o, Quoter=>$q);

$o->get_specs("$trunk/bin/pt-table-checksum");

my %common_modules = (
   Quoter       => $q,
   TableParser  => $tp,
   TableNibbler => $nb,
   OptionParser => $o,
);
my $in = "/t/lib/samples/NibbleIterator/";

sub make_nibble_iter {
   my (%args) = @_;

   if (my $file = $args{sql_file}) {
      $sb->load_file('master', "$in/$file");
   }

   @ARGV = $args{argv} ? @{$args{argv}} : ();
   $o->get_opts();

   my $schema = new Schema();
   my $si     = new SchemaIterator(
      dbh          => $dbh,
      keep_ddl     => 1,
      Schema       => $schema,
      %common_modules,
   );
   1 while $si->next_schema_object();

   my $ni = new NibbleIterator(
      dbh        => $dbh,
      tbl        => $schema->get_table($args{db}, $args{tbl}),
      chunk_size => $o->get('chunk-size'),
      callbacks  => $args{callbacks},
      select     => $args{select},
      %common_modules,
   );

   return $ni;
}

# ############################################################################
# a-z w/ chunk-size 5, z is final boundary and single value
# ############################################################################
my $ni = make_nibble_iter(
   sql_file => "a-z.sql",
   db       => 'test',
   tbl      => 't',
   argv     => [qw(--databases test --chunk-size 5)],
);

my @rows = ();
for (1..5) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [['a'],['b'],['c'],['d'],['e']],
   'a-z nibble 1'
) or print Dumper(\@rows);

@rows = ();
for (1..5) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [['f'],['g'],['h'],['i'],['j']],
   'a-z nibble 2'
) or print Dumper(\@rows);

@rows = ();
for (1..5) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [['k'],['l'],['m'],['n'],['o']],
   'a-z nibble 3'
) or print Dumper(\@rows);

@rows = ();
for (1..5) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [['p'],['q'],['r'],['s'],['t']],
   'a-z nibble 4'
) or print Dumper(\@rows);

@rows = ();
for (1..5) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [['u'],['v'],['w'],['x'],['y']],
   'a-z nibble 5'
) or print Dumper(\@rows);

# There's only 1 row left but extra calls shouldn't return anything or crash.
@rows = ();
for (1..5) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [['z']],
   'a-z nibble 6'
) or print Dumper(\@rows);

# ############################################################################
# a-y w/ chunk-size 5, even nibbles
# ############################################################################
$dbh->do('delete from test.t where c="z"');
my $all_rows = $dbh->selectall_arrayref('select * from test.t order by c');
$ni = make_nibble_iter(
   db       => 'test',
   tbl      => 't',
   argv     => [qw(--databases test --chunk-size 5)],
);

@rows = ();
for (1..26) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   $all_rows,
   'a-y even nibble'
) or print Dumper(\@rows);

# ############################################################################
# chunk-size exceeds number of rows, 1 nibble
# ############################################################################
$ni = make_nibble_iter(
   db       => 'test',
   tbl      => 't',
   argv     => [qw(--databases test --chunk-size 100)],
);

@rows = ();
for (1..27) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   $all_rows,
   '1 nibble'
) or print Dumper(\@rows);

# ############################################################################
# single row table
# ############################################################################
$dbh->do('delete from test.t where c != "d"');
$ni = make_nibble_iter(
   db       => 'test',
   tbl      => 't',
   argv     => [qw(--databases test --chunk-size 100)],
);

@rows = ();
for (1..3) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [['d']],
   'single row table'
) or print Dumper(\@rows);

# ############################################################################
# empty table
# ############################################################################
$dbh->do('truncate table test.t');
$ni = make_nibble_iter(
   db       => 'test',
   tbl      => 't',
   argv     => [qw(--databases test --chunk-size 100)],
);

@rows = ();
for (1..3) {
   push @rows, $ni->next();
}
is_deeply(
   \@rows,
   [],
   'empty table'
) or print Dumper(\@rows);

# ############################################################################
# Callbacks
# ############################################################################
$ni = make_nibble_iter(
   sql_file  => "a-z.sql",
   db        => 'test',
   tbl       => 't',
   argv      => [qw(--databases test --chunk-size 2)],
   callbacks => {
      init          => sub { print "init\n" },
      after_nibble  => sub { print "after nibble ".$ni->nibble_number()."\n" },
      done          => sub { print "done\n" },
   }
);

$dbh->do('delete from test.t limit 20');  # 6 rows left

my $output = output(
   sub {
      for (1..8) { $ni->next() }
   },
);

is(
   $output,
"init
after nibble 1
after nibble 2
after nibble 3
done
done
",
   "callbacks"
);

# ############################################################################
# Nibble a larger table by numeric pk id
# ############################################################################
SKIP: {
   skip "Sakila database is not loaded", 8
      unless @{ $dbh->selectall_arrayref('show databases like "sakila"') };

   $ni = make_nibble_iter(
      db       => 'sakila',
      tbl      => 'payment',
      argv     => [qw(--databases sakila --tables payment --chunk-size 100)],
   );

   my $n_nibbles = 0;
   $n_nibbles++ while $ni->next();
   is(
      $n_nibbles,
      16049,
      "Nibble sakila.payment (16049 rows)"
   );

   my $tbl = {
      db         => 'sakila',
      tbl        => 'country',
      tbl_struct => $tp->parse(
         $tp->get_create_table($dbh, 'sakila', 'country')),
   };
   my $chunk_checksum = $rc->make_chunk_checksum(
      dbh => $dbh,
      tbl => $tbl,
   );
   $ni = make_nibble_iter(
      db     => 'sakila',
      tbl    => 'country',
      argv   => [qw(--databases sakila --tables country --chunk-size 25)],
      select => $chunk_checksum,
   );

   my $row = $ni->next();
   is_deeply(
      $row,
      [25, 'da79784d'],
      "SELECT chunk checksum 1 FROM sakila.country"
   ) or print STDERR Dumper($row); 
   
   $row = $ni->next();
   is_deeply(
      $row,
      [25, 'e860c4f9'],
      "SELECT chunk checksum 2 FROM sakila.country"
   ) or print STDERR Dumper($row); 
   
   $row = $ni->next();
   is_deeply(
      $row,
      [25, 'eb651f58'],
      "SELECT chunk checksum 3 FROM sakila.country"
   ) or print STDERR Dumper($row); 
  
   $row = $ni->next();
   is_deeply(
      $row,
      [25, '2d87d588'],
      "SELECT chunk checksum 4 FROM sakila.country"
   ) or print STDERR Dumper($row); 
   
   $row = $ni->next();
   is_deeply(
      $row,
      [9, 'beb4a180'],
      "SELECT chunk checksum 5 FROM sakila.country"
   ) or print STDERR Dumper($row); 


   # #########################################################################
   # exec_nibble callback and explain_sth
   # #########################################################################
   my @expl;
   $ni = make_nibble_iter(
      db     => 'sakila',
      tbl    => 'country',
      argv   => [qw(--databases sakila --tables country --chunk-size 60)],
      select => $chunk_checksum,
      callbacks => {
         exec_nibble  => sub {
            my (%args) = @_;
            my ($expl_sth, $lb, $ub) = @args{qw(explain_sth lb ub)};
            $expl_sth->execute(@$lb, @$ub);
            push @expl, $expl_sth->fetchrow_hashref();
            return 0;
         },
      }
   );
   $ni->next();
   $ni->next();
   is_deeply(
      \@expl,
      [
         {
            id            => '1',
            key           => 'PRIMARY',
            key_len       => '2',
            possible_keys => 'PRIMARY',
            ref           => undef,
            rows          => '54',
            select_type   => 'SIMPLE',
            table         => 'country',
            type          => 'range',
            extra         => 'Using where',
         },
         {
            id             => '1',
            key            => 'PRIMARY',
            key_len        => '2',
            possible_keys  => 'PRIMARY',
            ref            => undef,
            rows           => '49',
            select_type    => 'SIMPLE',
            table          => 'country',
            type           => 'range',
            extra          => 'Using where',
         },
      ],
   'exec_nibble callbackup and explain_sth'
   );
    
   # #########################################################################
   # film_actor, multi-column pk
   # #########################################################################
   $ni = make_nibble_iter(
      db       => 'sakila',
      tbl      => 'film_actor',
      argv     => [qw(--tables sakila.film_actor --chunk-size 1000)],
   );

   $n_nibbles = 0;
   $n_nibbles++ while $ni->next();
   is(
      $n_nibbles,
      5462,
      "Nibble sakila.film_actor (multi-column pk)"
   );
}

# ############################################################################
# Reset chunk size on-the-fly. 
# ############################################################################
$ni = make_nibble_iter(
   sql_file  => "a-z.sql",
   db        => 'test',
   tbl       => 't',
   argv      => [qw(--databases test --chunk-size 5)],
);

@rows = ();
my $i = 0;
while (my $row = $ni->next()) {
   push @{$rows[$ni->nibble_number()]}, @$row;
   if ( ++$i == 5 ) {
      $ni->set_chunk_size(20);
   }
}

is_deeply(
   \@rows,
   [
      undef,          # no 0 nibble
      [ ('a'..'e') ], # nibble 1
      [ ('f'..'y') ], # nibble 2, should contain 20 chars
      [ 'z'        ], # last nibble
   ],
   "Change chunk size while nibbling"
) or print STDERR Dumper(\@rows);

# ############################################################################
# Nibble one row at a time.
# ############################################################################
$ni = make_nibble_iter(
   sql_file  => "a-z.sql",
   db        => 'test',
   tbl       => 't',
   argv      => [qw(--databases test --chunk-size 1)],
);

@rows = ();
while (my $row = $ni->next()) {
   push @rows, @$row;
}

is_deeply(
   \@rows,
   [ ('a'..'z') ],
   "Nibble by 1 row"
);

# #############################################################################
# Done.
# #############################################################################
$sb->wipe_clean($dbh);
exit;
