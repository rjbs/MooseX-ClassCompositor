use Test::More;
use Data::OptList;
use MooseX::ClassCompositor;

my $monkey_is_fed = undef;

BEGIN {
	package Local::My::Monkey;
	use Moose;
	sub feed {
		$monkey_is_fed = pop;
	}
}

BEGIN {
	package Local::My::MonkeyFeeding;
	use Moose::Role;
	requires qw(monkey);
	requires qw(food);
	sub feed_monkey {
		my $self = shift;
		$self->monkey->feed( $self->food );
	}
}

sub methods {
	Moose::Meta::Role->create_anon_role(
		methods => ( ref $_[0] eq 'HASH' ? $_[0] : +{@_} ),
	);
}

sub attributes {
	my %A = map {
		$_->[0] => Moose::Meta::Attribute->new(
			$_->[0],
			%{ $_->[1] || +{is=>'ro'} },
		);
	} @{ Data::OptList::mkopt(\@_) };
	Moose::Meta::Role->create_anon_role(attributes => \%A);
}

my $comp = MooseX::ClassCompositor->new(class_basename => 'Local::My');

my $class = $comp->class_for(
	'Local::My::MonkeyFeeding',
	attributes(qw( food monkey )),
	methods( answer => sub { 42 } ),
);

my $obj = $class->new(
	food   => 'bananas',
	monkey => Local::My::Monkey->new,
);

can_ok($obj, qw( food monkey feed_monkey answer ));

$obj->feed_monkey;
is($monkey_is_fed, $obj->food);

is($obj->answer, 42);

done_testing();
