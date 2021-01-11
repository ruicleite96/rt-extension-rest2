package RT::Extension::REST2::Resource;
use strict;
use warnings;

use Moose;
use MooseX::NonMoose;
use namespace::autoclean;
use RT::Extension::REST2::Util qw(expand_uid format_datetime custom_fields_for);

extends 'Web::Machine::Resource';

has 'current_user' => (
    is          => 'ro',
    isa         => 'RT::CurrentUser',
    required    => 1,
    lazy_build  => 1,
);

# XXX TODO: real sessions
sub _build_current_user {
    $_[0]->request->env->{"rt.current_user"} || RT::CurrentUser->new;
}

# Used in Serialize to allow additional fields to be selected ala JSON API on:
# http://jsonapi.org/examples/
sub expand_field {
    my $self  = shift;
    my $item  = shift;
    my $field = shift;
    my $param_prefix = shift || 'fields';

    my $result;
    if ($field eq 'CustomFields') {
        if (my $cfs = custom_fields_for($item)) {
            my %values;
            while (my $cf = $cfs->Next) {
                if (! defined $values{$cf->Id}) {
                    $values{$cf->Id} = {
                        %{ expand_uid($cf->UID) },
                        name   => $cf->Name,
                        values => [],
                    };
                }

                my $ocfvs = $cf->ValuesForObject($item);
                my $type  = $cf->Type;
                while ( my $ocfv = $ocfvs->Next ) {
                    my $content = $ocfv->Content;
                    if ( $type eq 'DateTime' ) {
                        $content = format_datetime($content);
                    }
                    elsif ( $type eq 'Image' or $type eq 'Binary' ) {
                        $content = {
                            content_type => $ocfv->ContentType,
                            filename     => $content,
                            _url         => RT::Extension::REST2->base_uri . "/download/cf/" . $ocfv->id,
                        };
                    }
                    push @{ $values{ $cf->Id }{values} }, $content;
                }
            }

            push @{ $result }, values %values if %values;
        }
    } elsif ($field eq 'Description' && $item->isa('RT::Ticket')) {
        my $transactions = $item->Transactions;
        $transactions->Limit(
            FIELD => 'Type',
            VALUE => 'Create'
        );
        if ($transactions->Count > 0) {
            my $contentObj = $transactions->First->ContentObj;
            if (defined $contentObj) {
                $result = $contentObj->Content;
            }
        }
    } elsif ($field eq 'MergedTickets') {
        my $method = 'Merged';
        my @obj = $item->$method;
        $result = \@obj;
    } elsif ($item->can('_Accessible') && $item->_Accessible($field => 'read')) {
        # RT::Record derived object, so we can check access permissions.

        if ($item->_Accessible($field => 'type') =~ /(datetime|timestamp)/i) {
            $result = format_datetime($item->$field);
        } elsif ($item->can($field . 'Obj')) {
            my $method = $field . 'Obj';
            my $obj = $item->$method;
            if ( $obj->can('UID') and $result = expand_uid( $obj->UID ) ) {
                my $param_field = $param_prefix . '[' . $field . ']';
                $self->expand_subfield($result, $obj, $param_field);
            }
        } elsif ($item->can($field) && defined blessed($item->$field) && $item->$field->isa('RT::Group')) {
	        my $members = $item->$field->MembersObj;
            my $param_field = $param_prefix . '[' . $field . ']';
	        my @objects;

            while (my $member = $members->Next) {
                my $user = RT::User->new($item->CurrentUser);
                $user->Load($member->MemberId);
                my $res = expand_uid($user->UID);
                $self->expand_subfield($res, $user, $param_field);
                push(@objects, $res);
            }
            $result = \@objects;
        }
        $result //= $item->$field;
    }

    return $result // '';
}

sub expand_subfield {
    my $self = shift;
    my $result = shift;
    my $obj = shift;
    my $param_field = shift;

    my @subfields = split( /,/, $self->request->param($param_field) || '' );

    for my $subfield (@subfields) {
        my $subfield_result = $self->expand_field( $obj, $subfield, $param_field );
        $result->{$subfield} = $subfield_result if defined $subfield_result;
    }
}

__PACKAGE__->meta->make_immutable;

1;
