package MooseX::ClassCompositor;
use Moose;

use namespace::autoclean;

use Memoize;
use MooseX::StrictConstructor::Trait::Class;
use Moose::Util qw(apply_all_roles);
use Moose::Util::MetaRole ();
use Scalar::Util qw(refaddr);
use String::RewritePrefix;

has class_basename => (
  is  => 'ro',
  isa => 'Str', # should be ~Perl::PkgName -- rjbs, 2011-08-05
  required => 1,
);

has class_metaroles => (
  reader  => '_class_metaroles',
  isa     => 'HashRef',
  default => sub {  {}  },
);

has known_classes => (
  reader   => '_known_classes',
  isa      => 'HashRef',
  traits   => [ 'Hash' ],
  handles  => {
    learn_class   => 'set',
    known_classes => 'elements',
  },
  init_arg => undef,
);

has role_prefixes => (
  is  => 'ro',
  isa => 'HashRef',
  default => sub {  {}  },
);

sub _rewrite_roles {
  my ($self, @in) = @_;
  return String::RewritePrefix->rewrite($self->role_prefixes, @in);
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

  $self->learn_class($name, \@orig_args);
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
  my $key = join "; ", @k;
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


1;
