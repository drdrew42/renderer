use strict;
use warnings;

package RenderApp::Model::JWT;

use Crypt::JWT qw( encode_jwt decode_jwt );
use Data::Structure::Util qw( unbless );

# first argument is possibly a payload hash,
# otherwise create a jwt shell with an empty payload
sub new {
    my $class = shift;
    my $payload = ( ref($_[0]) =~ /HASH/ ) ? shift : {};
    my %args = @_;

    my $self = {
        payload => $payload,
        auto_iat => 1,
        alg => 'PBES2-HS512+A256KW',
        enc => 'A256GCM',
        iss => $ENV{SITE_HOST},
        key => $ENV{webworkJWTsecret}
    };
    map {$self->{$_} = $args{$_}} keys %args;
    return bless $self, $class;
}

sub set {
    my $self = shift;
    my $key_name = shift;
    my $value = shift if scalar(@_) == 1;
    return $self->{$key_name} unless defined $value;
    die "Do not set payload data with `set`." if $key_name eq 'payload';

    $self->{$key_name} = $value;
    return $self;
}

# we want to be able to push content to the payload
# without overriding existing content -- flesh this out
# should be limited to scalar values.
sub payload {
    my $self = shift;
    my $key_name = shift;
    my $value = shift if scalar(@_) == 1;
    return $self->{payload}{$key_name} unless defined $value;
    $self->{payload}{$key_name} = $value;
    return $self;

}

# for arrays in payload
sub push {
    my $self = shift;
    my $key_name = shift;
    my $value = shift if scalar(@_) == 1;
    return $self->{payload}{$key_name} unless defined $value;
    $self->{payload}{$key_name} = [] unless defined $self->{payload}{$key_name};
    die "$key_name is not an array" unless ref($self->{payload}{$key_name}) =~ /ARRAY/;
    push @{$self->{$key_name}}, $value;
    return $self;
}

sub encode {
    my $self = shift;
    return encode_jwt(%$self);
}

sub decode {
    my $self = decode_jwt(token => shift, @_);
    return RenderApp::Model::JWT->new($self);
}

1;