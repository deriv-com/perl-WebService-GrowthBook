package WebService::GrowthBook::Eval;
use strict;
use warnings;
no indirect;
use Exporter 'import';
use Scalar::Util qw(looks_like_number);
use Data::Dumper;
use Syntax::Keyword::Try;
use JSON::MaybeXS qw(is_bool);
our @EXPORT_OK = qw(eval_condition);
sub debug {
    print STDERR Dumper(\@_);
}

sub eval_condition {
    my ($attributes, $condition) = @_;
    if (exists $condition->{"\$or"}) {
        my $r = eval_or($attributes, $condition->{"\$or"});
        debug("eval_or", $attributes, $condition->{'$or'}, $r);
        return $r;
    }
    if (exists $condition->{"\$nor"}) {
        return !eval_or($attributes, $condition->{"\$nor"});
    }
    if (exists $condition->{"\$and"}) {
        my $r = eval_and($attributes, $condition->{"\$and"});
        debug("eval_and", $attributes, $condition->{'$and'}, $r);
        return $r;
    }
    if (exists $condition->{"\$not"}) {
        return !eval_condition($attributes, $condition->{"\$not"});
    }

    while (my ($key, $value) = each %$condition) {
        debug('calling get_path', $attributes, $key);
        if (!eval_condition_value($value, get_path($attributes, $key))) {
            debug("eval_condition_value in eval_condition", $value, get_path($attributes, $key), 0);
            return 0;
        }
    }

    return 1;
}

sub get_path {
    my ($attributes, $path) = @_;
    my $current = $attributes;

    foreach my $segment (split /\./, $path) {
        if (ref($current) eq 'HASH' && exists $current->{$segment}) {
            $current = $current->{$segment};
        } else {
            return undef;
        }
    }
    return $current;
}

sub eval_or {
    my ($attributes, $conditions) = @_;

    if (scalar @$conditions == 0) {
        return 1;  # True
    }

    foreach my $condition (@$conditions) {
        if (eval_condition($attributes, $condition)) {
            return 1;  # True
        }
    }
    return 0;  # False
}
sub eval_and {
    my ($attributes, $conditions) = @_;

    foreach my $condition (@$conditions) {
        if (!eval_condition($attributes, $condition)) {
            debug("eval_condition", $attributes, $condition, 0);
            return 0;  # False
        }
    }
    return 1;  # True
}

# TODO turn 1 and 0 to json true and false

sub eval_condition_value {
    my ($condition_value, $attribute_value) = @_;
    debug("eval_condition_value", $condition_value, $attribute_value);
    if (ref($condition_value) eq 'HASH' && is_operator_object($condition_value)) {
        while (my ($key, $value) = each %$condition_value) {
            if (!eval_operator_condition($key, $attribute_value, $value)) {
                debug("eval_operator_condition", $key, $attribute_value, $value, 0);
                return 0;  # False
            }
        }
        return 1;  # True
    }
    if (ref($condition_value) eq 'ARRAY') {
        if(ref($attribute_value) ne 'ARRAY'){
            return 0;
        }
        if(scalar @$condition_value != scalar @$attribute_value){
            return 0;
        }
        for my $i (0..$#$condition_value){
            if(!eval_condition_value($condition_value->[$i], $attribute_value->[$i])){
                return 0;
            }
        }
        return 1;
    }

    if(ref($condition_value) eq 'HASH'){
        if(ref($attribute_value) ne 'HASH'){
            return 0;
        }
        if(scalar keys %$condition_value != scalar keys %$attribute_value){
            return 0;
        }
        for my $key (keys %$condition_value){
            if(!exists $attribute_value->{$key}){
                return 0;
            }
            if(!eval_condition_value($condition_value->{$key}, $attribute_value->{$key})){
                debug("here in hash", $condition_value, $attribute_value, 0);
                return 0;
            }
        }
        return 1;

    }
    debug('------------here eq ?', $condition_value, $attribute_value, 1);
    return $condition_value eq $attribute_value;
}

sub is_operator_object {
    my ($obj) = @_;

    foreach my $key (keys %$obj) {
        if (substr($key, 0, 1) ne '$') {
            return 0;  # False
        }
    }
    return 1;  # True
}

sub compare {
    my ($a, $b) = @_;
    if(looks_like_number($a) && not defined($b)){
        $b = 0;
    }
    if(looks_like_number($b) && not defined($a)){
        $a = 0;
    }
    debug("after set compare", $a, $b);
    if(looks_like_number($a) && looks_like_number($b)){
        return $a <=> $b;
    }
    else {
        return $a cmp $b;
    }
}
sub eval_operator_condition {
    my ($operator, $attribute_value, $condition_value) = @_;
    debug("eval_operator_condition", $operator, $attribute_value, $condition_value);
    if ($operator eq '$eq') {
        try {
            return compare($attribute_value, $condition_value) == 0;
        } 
        catch {
            return 0;
        }
    } elsif ($operator eq '$ne') {
        try {
            return compare($attribute_value, $condition_value) != 0;
        } 
        catch {
            return 0;
        }
    } elsif ($operator eq '$lt') {
        try {
            return compare($attribute_value, $condition_value) < 0;
        }
        catch {
            return 0;
        }
    } elsif ($operator eq '$lte') {
        try {
            return compare($attribute_value, $condition_value) <= 0;
        }
        catch {
            return 0;
        }
    } elsif ($operator eq '$gt') {
        try {
            my $r = compare($attribute_value, $condition_value);
            debug("compare gt", $attribute_value, $condition_value, $r);
            return $r > 0;
        }
        catch {
            return 0;
        }
    } elsif ($operator eq '$gte') {
        try {
            return compare($attribute_value, $condition_value) >= 0;
        }
        catch {
            return 0;
        }
    } elsif ($operator eq '$veq') {
        return padded_version_string($attribute_value) eq padded_version_string($condition_value);
    } elsif ($operator eq '$vne') {
        return padded_version_string($attribute_value) ne padded_version_string($condition_value);
    } elsif ($operator eq '$vlt') {
        return padded_version_string($attribute_value) lt padded_version_string($condition_value);
    } elsif ($operator eq '$vlte') {
        return padded_version_string($attribute_value) le padded_version_string($condition_value);
    } elsif ($operator eq '$vgt') {
        return padded_version_string($attribute_value) gt padded_version_string($condition_value);
    } elsif ($operator eq '$vgte') {
        return padded_version_string($attribute_value) ge padded_version_string($condition_value);
    } elsif ($operator eq '$regex') {
        try {
            my $r = qr/$condition_value/;
            return $attribute_value =~ $r;
        }
        catch {
            return 0;
        }
    } elsif ($operator eq '$in') {
        return 0 unless ref($condition_value) eq 'ARRAY';
        return is_in($condition_value, $attribute_value);
    } elsif ($operator eq '$nin') {
        return 0 unless ref($condition_value) eq 'ARRAY';
        return !is_in($condition_value, $attribute_value);
    } elsif ($operator eq '$elemMatch') {
        return elem_match($condition_value, $attribute_value);
    } elsif ($operator eq '$size') {
        return 0 unless ref($attribute_value) eq 'ARRAY';
        return eval_condition_value($condition_value, scalar @$attribute_value);
    } elsif ($operator eq '$all') {
        return 0 unless ref($attribute_value) eq 'ARRAY';
        foreach my $cond (@$condition_value) {
            my $passing = 0;
            foreach my $attr (@$attribute_value) {
                if (eval_condition_value($cond, $attr)) {
                    $passing = 1;
                    last;
                }
            }
            return 0 unless $passing;
        }
        return 1;
    } elsif ($operator eq '$exists') {
        return !$condition_value ? !defined $attribute_value : defined $attribute_value;
    } elsif ($operator eq '$type') {
        my $r = get_type($attribute_value);
        debug("type", $attribute_value, $r);
        return $r eq $condition_value;
    } elsif ($operator eq '$not') {
        return !eval_condition_value($condition_value, $attribute_value);
    }
    return 0;
}


sub padded_version_string {
    my ($input) = @_;

    # If input is a number, convert to a string
    if (looks_like_number($input)) {
        $input = "$input";
    }

    if (!defined $input || ref($input) || $input eq '') {
        $input = "0";
    }

    # Remove build info and leading `v` if any
    $input =~ s/^v|\+.*$//g;

    # Split version into parts (both core version numbers and pre-release tags)
    my @parts = split(/[-.]/, $input);

    # If it's SemVer without a pre-release, add `~` to the end
    if (scalar(@parts) == 3) {
        push @parts, "~";
    }

    # Left pad each numeric part with spaces so string comparisons will work ("9">"10", but " 9"<"10")
    @parts = map { /^\d+$/ ? sprintf("%5s", $_) : $_ } @parts;

    # Join back together into a single string
    return join("-", @parts);
}
sub is_in {
    my ($condition_value, $attribute_value) = @_;
    return 0 unless defined($attribute_value);
    debug('is_in', @_);
    if (ref($attribute_value) eq 'ARRAY') {
        my %condition_hash = map { $_ => 1 } @$condition_value;
        foreach my $item (@$attribute_value) {
            return 1 if exists $condition_hash{$item};
        }
        return 0;
    }
    return grep { $_ eq $attribute_value } @$condition_value;
}

sub elem_match {
    my ($condition, $attribute_value) = @_;

    # Check if $attribute_value is an array reference
    return 0 unless ref($attribute_value) eq 'ARRAY';

    foreach my $item (@$attribute_value) {
        if (is_operator_object($condition)) {
            if (eval_condition_value($condition, $item)) {
                return 1;
            }
        } else {
            if (eval_condition($item, $condition)) {
                return 1;
            }
        }
    }

    return 0;
}

sub get_type {
    my ($attribute_value) = @_;
    debug('get_type in function', $attribute_value);
    if (!defined $attribute_value) {
        return "null";
    }
    if (ref($attribute_value) eq '') {
        if ($attribute_value =~ /^[+-]?\d+$/ || $attribute_value =~ /^[+-]?\d*\.\d+$/) {
            return "number";
        }
        return "string";
    }
    if (is_bool($attribute_value)) {
        return "boolean";
    }
    if (ref($attribute_value) eq 'ARRAY') {
        return "array";
    }
    if (ref($attribute_value) eq 'HASH') {
        return "object";
    }
    if (ref($attribute_value) eq 'SCALAR' && ($$attribute_value eq '0' || $$attribute_value eq '1')) {
        return "boolean";
    }
    return "unknown";
}

1;