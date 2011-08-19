package MooseX::ClassCompositor;
use Moose;
# ABSTRACT: a factory that builds classes from roles

use namespace::autoclean;

use Moose::Util qw(apply_all_roles);
use Moose::Util::MetaRole ();
use MooseX::StrictConstructor::Trait::Class;
use MooseX::Types::Perl qw(PackageName);
use Scalar::Util qw(refaddr);
use String::RewritePrefix;

=head1 ABSTRACT

  my $comp = MooseX::ClassCompositor->new({
    class_basename  => 'MyApp::Class',
    class_metaroles => {
      class => [ 'MooseX::StrictConstructor::Trait::Class' ],
    },
    role_prefixes   => {
      ''  => 'MyApp::Role::',
      '=' => '',
    },
  });

  my $class = $comp->class_for( qw( PieEater ContestWinner ) );

  my $object = $class->new({
    pie_type => 'banana',
    place    => '2nd',
  });

=head1 OVERVIEW

A MooseX::ClassCompositor is a class factory.  If you think using a class
factory will make you feel like a filthy "enterprise" programmer, maybe you
should turn back now.

The compositor has a C<L</class_for>> method that builds a class by combining a
list of roles with L<Moose::Object>, applying any supplied metaclass, and
producing an arbitrary-but-human-scannable name.  The metaclass is then
made immutable, the operation is memoized, and the class name is returned.

In the L</SYNOPSIS> above, you can see all the major features used:
C<class_metaroles> to enable strict constructors, C<role_prefixes> to use
L<String::RewritePrefix> to expand role name shorthand, and C<class_basename>
to pick a namespace under which to put constructed classes.

Not shown is the C<L</known_classes>> method, which returns a list of pairs
describing all the classes that the factory has constructed.  This method can
be useful for debugging and other somewhat esoteric purposes like
serialization.

=cut

=attr class_basename

This attribute must be given, and must be a valid Perl package name.
Constructed classes will all be under this namespace.

=cut

has class_basename => (
  is  => 'ro',
  isa => PackageName,
  required => 1,
);

=attr class_metaroles

This attribute, if given, must be a hashref of class metaroles that will be
applied to newly-constructed classes with
L<Moose::Util::MetaRole::apply_metaroles>.

=cut

has class_metaroles => (
  reader  => '_class_metaroles',
  isa     => 'HashRef',
  default => sub {  {}  },
);

=attr known_classes

This attribute stores a mapping of class names to the parameters used to
construct them.  The C<known_classes> method returns its contents as a list of
pairs.

=cut

has known_classes => (
  reader   => '_known_classes',
  isa      => 'HashRef',
  traits   => [ 'Hash' ],
  handles  => {
    _learn_class   => 'set',
    known_classes => 'elements',
  },
  init_arg => undef,
  default  => sub {  {}  },
);

=attr role_prefixes

This attribute is used as the arguments to L<String::RewritePrefix> for
expanding role names passed to the compositor's L<class_for> method.

=cut

has role_prefixes => (
  reader  => '_role_prefixes',
  isa     => 'HashRef',
  default => sub {  {}  },
);

sub _rewrite_roles {
  my ($self, @in) = @_;
  return String::RewritePrefix->rewrite($self->_role_prefixes, @in);
}

has serial_counter => (
  reader  => '_serial_counter',
  isa     => 'Str',
  default => 'AA',
  traits  => [ 'String' ],
  handles => { next_serial => 'inc' },
  init_arg => undef,
);

has _memoization_table => (
  is  => 'ro',
  isa => 'HashRef',
  default  => sub {  {}  },
  traits   => [ 'Hash' ],
  handles  => {
    _class_for_key     => 'get',
    _set_class_for_key => 'set',
  },
  init_arg => undef,
);

=method class_for

  my $class = $compositor->class_for(

    'Role::Name', # <-- will be expanded with role_prefixes

    [
      'Param::Role::Name', #  <-- will be expanded with role_prefixes
      'ApplicationName',   #  <-- will not be touched
      { ...param... },
    ],
  );

This method will return a class with the roles passed to it.  They can be given
either as names (which will be expanded according to C<L</role_prefixes>>) or
as arrayrefs containing a role name, application name, and hashref of
parameters.  In the arrayref form, the application name is just a name used to
uniquely identify this application of a parameterized role, so that they can be
applied multiple times with each application accounted for internally.

Note that at present, passing Moose::Meta::Role objects is B<not> supported.
This should change in the future.

=cut

sub class_for {
  my ($self, @args) = @_;

  # can't use memoize without losing subclassability, so we reimplemented
  # -- rjbs, 2011-08-05
  my $memo_key = $self->_memoization_key(\@args);
  if (my $cached = $self->_class_for_key($memo_key)) {
    return $cached;
  }

  # Arguments here are role names, or role objects followed by nonce-names.
  my @orig_args = @args;

  # $role_hash is a hash mapping nonce-names to role objects
  # $role_names is an array of names of more roles to add
  my (@roles, @role_class_names, @all_names);

  while (@args) {
    my $name = shift @args;
    if (ref $name) {
      my ($role_name, $moniker, $params) = @$name;

      my $full_name = $self->_rewrite_roles($role_name);
      Class::MOP::load_class($full_name);
      my $role_object = $full_name->meta->generate_role(
        parameters => $params,
      );

      push @roles, $role_object;
      $name = $moniker;
    } else {
      push @role_class_names, $name;
    }

    $name =~ s/::/_/g if @all_names;
    $name =~ s/^=//;

    push @all_names, $name;
  }

  my $name = join q{::}, $self->class_basename, @all_names;

  @role_class_names = $self->_rewrite_roles(@role_class_names);

  Class::MOP::load_class($_) for @role_class_names;

  if ($name->can('meta')) {
    $name .= "_" . $self->next_serial;
  }

  my $class = Moose::Meta::Class->create( $name => (
    superclasses => [ 'Moose::Object' ],
  ));

  apply_all_roles($class, @role_class_names, map $_->name, @roles);

  $class = Moose::Util::MetaRole::apply_metaroles(
    for => $class->name,
    class_metaroles => $self->_class_metaroles,
  );

  $class->make_immutable;

  $self->_learn_class($name, \@orig_args);
  $self->_set_class_for_key($memo_key, $name);

  return $class->name;
}

sub _memoization_key {
  my ($self, $args) = @_;
  my @args = @$args;

  my @k;
  while (@args) {
    my $arg = shift @args;
    if (ref $arg) {
      my ($role_name, $moniker, $params) = @$arg;
      push @k, "$moniker : { " . __hash_to_string($params) . " }";
    } else {
      push @k, $arg;
    }
  }
  my $key = join "; ", sort @k;
  return $key;
}

sub __hash_to_string {
  my ($h) = @_;
  my @k;
  for my $k (sort keys %$h) {
    my $v = ! defined($h->{$k}) ? "<undef>" :
              ref($h->{$k}) ? join("-", @{$h->{$k}}) : $h->{$k};
    push @k, "$k => $v";
  }
  join ", " => @k;
}

__PACKAGE__->meta->make_immutable;
1;
