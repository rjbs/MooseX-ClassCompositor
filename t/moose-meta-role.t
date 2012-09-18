use strict;
use warnings;

use Test::More;
use MooseX::ClassCompositor;
use t::lib::BasicBar;

my $comp_2 = MooseX::ClassCompositor->new({
 class_basename  => 'MXCC::Test',
 class_metaroles => {
	class => [ 'MooseX::StrictConstructor::Trait::Class' ],
 },
 fixed_roles => [ 'BasicFoo' ],
 role_prefixes   => {
	'' => 't::lib::',
 },
});

my $class = $comp_2->class_for( t::lib::BasicBar->meta );

ok($class->does('t::lib::BasicFoo'));
ok($class->does('t::lib::BasicBar'));

done_testing;
