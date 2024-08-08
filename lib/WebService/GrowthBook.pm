package WebService::GrowthBook;
# ABSTRACT: ...

use strict;
use warnings;
no indirect;
use feature qw(state);
use Object::Pad;
use JSON::MaybeUTF8 qw(decode_json_text);
use Scalar::Util qw(blessed);
use Log::Any qw($log);
use WebService::GrowthBook::FeatureRepository;
use WebService::GrowthBook::Feature;
use WebService::GrowthBook::FeatureResult;
use WebService::GrowthBook::InMemoryFeatureCache;
use WebService::GrowthBook::Eval qw(eval_condition);
use WebService::GrowthBook::Util qw(gbhash in_range);

our $VERSION = '0.003';

=head1 NAME

WebService::GrowthBook - sdk of growthbook

=head1 SYNOPSIS

    use WebService::GrowthBook;
    my $instance = WebService::GrowthBook->new(client_key => 'my key');
    $instance->load_features;
    if($instance->is_on('feature_name')){
        # do something
    }
    else {
        # do something else
    }
    my $string_feature = $instance->get_feature_value('string_feature');
    my $number_feature = $instance->get_feature_value('number_feature');
    # get decoded json
    my $json_feature = $instance->get_feature_value('json_feature');

=head1 DESCRIPTION

    This module is a sdk of growthbook, it provides a simple way to use growthbook features.

=cut

# singletons

class WebService::GrowthBook {
    field $url :param //= 'https://cdn.growthbook.io';
    field $client_key :param;
    field $features :param //= {};
    field $attributes :param :reader :writer //= {};
    field $cache_ttl :param //= 60;
    field $user :param //= {};
    field $cache //= WebService::GrowthBook::InMemoryFeatureCache->singleton;
    method load_features {
        my $feature_repository = WebService::GrowthBook::FeatureRepository->new(cache => $cache);
        my $loaded_features = $feature_repository->load_features($url, $client_key, $cache_ttl);
        if($loaded_features){
            $self->set_features($loaded_features);
            return 1;
        }
        return undef;
    }
    method set_features($features_set) {
        $features = {};
        for my $feature_id (keys $features_set->%*) {
            my $feature = $features_set->{$feature_id};
            if(blessed($feature) && $feature->isa('WebService::GrowthBook::Feature')){
                $features->{$feature->id} = $feature;
            }
            else {
                $features->{$feature_id} = WebService::GrowthBook::Feature->new(id => $feature_id, default_value => $feature->{defaultValue}, rules => $feature->{rules});
            }
        }
    }
    
    method is_on($feature_name) {
        my $result = $self->eval_feature($feature_name);
        return undef unless defined($result);
        return $result->on;
    }
    
    method is_off($feature_name) {
        my $result = $self->eval_feature($feature_name);
        return undef unless defined($result);
        return $result->off;
    }
    
    # I don't know why it is called stack. In fact it is a hash/dict
    method $eval_feature($feature_name, $stack){
        $log->debug("Evaluating feature $feature_name");
        if(!exists($features->{$feature_name})){
            $log->debugf("No such feature: %s", $feature_name);
            return WebService::GrowthBook::FeatureResult->new(id => $feature_name, value => undef, source => "unknownFeature");
        }

        if ($stack->{$feature_name}) {
            $log->warnf("Cyclic prerequisite detected, stack: %s", $stack);
            return WebService::GrowthBook::FeatureResult->new(id => $feature_name, value => undef, source => "cyclicPrerequisite");
        }
        
        $stack->{$feature_name} = 1;

        my $feature = $features->{$feature_name};
        for my $rule (@{$feature->rules}){
            $log->debugf("Evaluating feature %s, rule %s", $feature_name, $rule.to_hash());
            if ($rule->parentConditions){
                my $prereq_res = $self->eval_prereqs($rule->parentConditions, $stack);
                if ($prereq_res eq "gate") {
                    $log->debugf("Top-lavel prerequisite failed, return undef, feature %s", $feature_name);
                    return WebService::GrowthBook::FeatureResult->new(id => $feature_name, value => undef, source => "prerequisite");
                }
                elsif ($prereq_res eq "cyclic") {
                    return WebService::GrowthBook::FeatureResult->new(id => $feature_name, value => undef, source => "cyclicPrerequisite");
                }
                elsif ($prereq_res eq "fail") {
                    $log->debugf("Skip rule becasue of failing prerequisite, feature %s", $feature_name);
                    continue;
                }
            }

            if ($rule->condition){
                if (!eval_condition($self->attributes, $rule->condition)){
                    $log->debugf("Skip rule because of failed condition, feature %s", $feature_name);
                    continue;
                }
            }

            if ($rule->force){
                if(!$self->is_included_in_rollout($rule->seed || $feature_name,
                    $rule->hash_attribute,
                    $rule->fallback_attribute,
                    $rule->range,
                    $rule->coverage,
                    $rule->hash_version
                )){
                    $log->debugf(
                        "Skip rule because user not included in percentage rollout, feature %s",
                        $feature_name,
                    );
                    continue;
                }
            }

            if($rule->variations){
                $log->warnf("Skip invalid rule, feature %s", $feature_name);
                continue;
            }
            
            # TODO implement experiment first


        }
        my $default_value = $feature->default_value;
    
        return WebService::GrowthBook::FeatureResult->new(
            id => $feature_name,
            value => $default_value,
            source => "default" # TODO fix this, maybe not default
            );
    }


    method _is_included_in_rollout($seed, $hash_attribute, $fallback_attribute, $range, $coverage, $hash_version){
        if (!defined($coverage) && !defined($range)){
            return 1;
        }
        my $hash_value;
        (undef, $hash_value) = $self->_get_hash_value($hash_attribute, $fallback_attribute);
        if($hash_value eq "") {
            return 0;
        }

        my $n = gbhash($seed, $hash_value, $hash_version || 1);

        if (!defined($n)){
            return 0;
        }

        if($range){
            return in_range($n, $range);
        }
        elsif($coverage){
            return $n < $coverage;
        }

        return 1;
    }

    method _get_hash_value($attr, $fallback_attr){
        my $val;
        ($attr, $val) = $self->_get_orig_hash_value($attr, $fallback_attr);
        return ($attr, "$val");
    }
    
    method _get_orig_hash_value($attr, $fallback_attr){
        $attr ||= "id";
        my $val = "";
        
        if (exists $attributes->{$attr}) {
            $val = $attributes->{$attr} || "";
        } elsif (exists $user->{$attr}) {
            $val = $user->{$attr} || "";
        }

        # If no match, try fallback
        if ((!$val || $val eq "") && $fallback_attr && $self->{sticky_bucket_service}) {
            if (exists $attributes->{$fallback_attr}) {
                $val = $attributes->{$fallback_attr} || "";
            } elsif (exists $user->{$fallback_attr}) {
                $val = $user->{$fallback_attr} || "";
            }
        
            if (!$val || $val ne "") {
                $attr = $fallback_attr;
            }
        }
        
        return ($attr, $val);
    }

    method eval_prereqs($parent_conditions, $stack){
        foreach my $parent_condition (@$parent_conditions) {
            my $parent_res = $self->$eval_feature($parent_condition->{id}, $stack);
    
            if ($parent_res->{source} eq "cyclicPrerequisite") {
                return "cyclic";
            }
    
            if (!eval_condition({ value => $parent_res->{value} }, $parent_condition->{condition})) {
                if ($parent_condition->{gate}) {
                    return "gate";
                }
                return "fail";
            }
        }
        return "pass";
    }
    method eval_feature($feature_name){
        return $self->$eval_feature($feature_name, {});
    }
   
    method get_feature_value($feature_name, $fallback = undef){
        my $result = $self->eval_feature($feature_name);
        return $fallback unless defined($result->value);
        return $result->value;
    }
}

=head1 METHODS

=head2 load_features

load features from growthbook API

    $instance->load_features;

=head2 is_on

check if a feature is on

    $instance->is_on('feature_name');

Please note it will return undef if the feature does not exist.

=head2 is_off

check if a feature is off

    $instance->is_off('feature_name');

Please note it will return undef if the feature does not exist.

=head2 get_feature_value

get the value of a feature

    $instance->get_feature_value('feature_name');

Please note it will return undef if the feature does not exist.

=head2 set_features

set features

    $instance->set_features($features);

=head2 eval_feature

evaluate a feature to get the value

    $instance->eval_feature('feature_name');

=cut

1;


=head1 SEE ALSO

=over 4

=item * L<https://docs.growthbook.io/>

=item * L<PYTHON VERSION|https://github.com/growthbook/growthbook-python>

=back

