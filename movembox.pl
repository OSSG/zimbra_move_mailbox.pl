#!/usr/bin/perl

# Zimbra mailbox movement tool
#
# Copyright (C) 2022 Fedor A. Fetisov <faf@oits.ru>. All Rights Reserved
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License

use strict;
use warnings;

# Use configuration constants
use FindBin;
use lib $FindBin::Bin;
use Constants;

use Data::Dumper;
use Getopt::Long qw(:config no_ignore_case bundling no_auto_abbrev);

# Set environment localization constants
$ENV{LC_CTYPE} = LOCALE_LC_CTYPE;
$ENV{LANG} = LOCALE_LANG;
$ENV{LC_ALL} = LOCALE_LC_ALL;

# Enable output in color if it's possible
my $color = 0;
eval "use Term::ANSIColor;";
$color = $@ ? 0 : 1;

# Disable buffering
$| = 1;

# Store start time
my $begin = time;

# Immutable (service) attributes to ignore
my $service_attributes = {
    'properties' => { 'mail' => 1,
                      'objectClass' => 1,
                      'uid' => 1,
                      'zimbraCreateTimestamp' => 1,
                      'zimbraCOSId' => 1,
                      'zimbraId' => 1,
                      'zimbraLastLogonTimestamp' => 1,
                      'zimbraMailAlias' => 1,
                      'zimbraMailHost' => 1,
                      'zimbraMailTransport' => 1,
                      'zimbraMailDeliveryAddress' => 1
     },
    'identities' => {
                      'objectClass' => 1,
                      'zimbraPrefIdentityId' => 1
    }
};

# "Immutable" attributes to change via LDAP
my $special_attributes = {
  'zimbraCreateTimestamp' => 1,
  'zimbraLastLogonTimestamp' => 1
};

# Storage for attributes with references to other entities (i.e. signatures)
my $refs = {
    'properties' => {},
    'identities' => {}
};

# Storage for references replacement table
my $replacements = {};

# Check system UID
my $login = getlogin || getpwuid($<) || '';
if ($login ne 'zimbra') {
    write_to_log('error',  'This program must be run under Zimbra account');
    exit(1);
}

# Get command line options
my $options = {};
unless ( GetOptions( $options,
                     'acc|a=s',
                     'dest|d=s',
                     'temp|t=s',
                     'dry-run|d',
                     'skip-emails|s',
                     'verbose|v',
                     'vverbose|vv' ) &&
         exists($options->{'acc'}) &&
         exists($options->{'dest'}) ) {

    print STDERR "Usage: $0 --acc <account to move> --dest <store to move account into> [--temp <location of a temporary directory, default: /tmp/movembox>] [--[v]verbose|-[v]v] [--dry-run|d] [--skip-emails|s]\n";
    exit(2);
}

$options->{'verbose'} ||= 0;
$options->{'vverbose'} ||= 0;
$options->{'dry-run'} ||= 0;
$options->{'skip-emails'} ||= 0;
$options->{'temp'} ||= '/tmp/movembox';

write_to_log('debug', 'Running in ' . ($options->{'dry-run'} ? 'dry run' : 'real') . ' mode');

# Check temporary directory
write_to_log('info', 'Check temporary directory to exists and be writable');
unless (-d $options->{'temp'} && -w $options->{'temp'}) {
    write_to_log('error', 'Temporary directory ' . $options->{'temp'} . ' not exists or not writable');
    exit(3);
}

my $old_account = 'old-' . $options->{'acc'};
write_to_log('info', "Check that old account $old_account does not exist");
my $raw = `@{[ LOCALE ]} @{[ ZMPROV ]} getAccount $old_account 2>/dev/null`;
if ($raw) {
    write_to_log('error', "Old account $old_account is already exists, delete it first");
    if ($options->{'dry-run'}) {
        write_to_log('debug', 'Running in dry run mode, continue');
    }
    else {
        exit(4);
    }
}

my $account = $options->{'acc'};
write_to_log('info', "Get account $account");
$raw = `@{[ LOCALE ]} @{[ ZMPROV ]} -l getAccount $account`;
unless ($raw) {
    write_to_log('error',  "Failed to get account $account");
    exit(5);
}

my $properties = raw_to_hash($raw);
write_to_log('debug', 'Got ' . scalar(keys(%$properties)) . ' properties');

# Check whether we're trying to relocate an ordinary account
if ( ($properties->{'cn'} eq 'admin')
     || ($properties->{'cn'} eq 'wiki')
     || ($properties->{'cn'} eq 'galsync')
     || ($properties->{'cn'} eq 'ham')
     || ($properties->{'cn'} eq 'span') ) {

    write_to_log('error',  'Unable to move service account');
    exit(6);
}

# Check whether account is not already relocated
if (!exists($properties->{'zimbraMailHost'})) {
    write_to_log('error', 'Very strange: zimbraMailHost property not found!');
    exit(7);
}
elsif ($properties->{'zimbraMailHost'} eq $options->{'dest'}) {
    write_to_log('warn',"'Account $account is already at " . $options->{'dest'} . ' store, nothing to do!');
    if ($options->{'dry-run'}) {
        write_to_log('debug', 'Running in dry run mode, continue');
    }
    else {
        exit(0);
    }
}

# Define class of service and get its settings
write_to_log('info', 'Determine COS for the account');
my $cos_id = '';
if (exists($properties->{'zimbraCOSId'})) {
    $cos_id = $properties->{'zimbraCOSId'};
    write_to_log('debug', "Account has COS with id $cos_id");
    $raw = `@{[ LOCALE ]} @{[ ZMPROV ]} getCos $cos_id`;
}
else {
    write_to_log('debug', "Account has no explicitly set COS, try to get default one");
    $raw = `@{[ LOCALE ]} @{[ ZMPROV ]} getCos default`;
}
my $cos = raw_to_hash($raw);

# Compare CoS settings and actual account properties, leave only differences in account properties
my $cnt = 0;
foreach (keys(%$properties)) {
    if (exists($cos->{$_}) && (ref($cos->{$_}) eq ref($properties->{$_}))) {
        if (ref($cos->{$_}) eq 'ARRAY') {
            delete($properties->{$_}) if compare_arrays($cos->{$_}, $properties->{$_});
            $cnt++;
        }
        elsif ($cos->{$_} eq $properties->{$_}) {
            delete($properties->{$_});
            $cnt++;
        }
    }
}
write_to_log('debug', "Removed $cnt properties defined by CoS, " . scalar(keys(%$properties)) . ' properties remained');

# Get identities
write_to_log('info', 'Get related identities');
my $identities = {};
$raw = `@{[ LOCALE ]} @{[ ZMPROV ]} getIdentities $account`;
unless ($raw) {
    write_to_log('error',  'Very strange: identities not found!');
    exit(8);
}
else {
    my $name = '';
    my $key = '';
    my $val = '';
    my $flag = 0;
    foreach (split("\n", $raw)) {
# Each item in printed list of identities starts with a comment containing a name of identity
        if (/^# name (.+)$/) {
            $name = $1;
            if (exists($identities->{$name})) {
                write_to_log('error', "Very strange: duplicate identity $name encountered");
                exit(9);
            }
            else {
                $identities->{$name} = {};
            }
        }
        else {
# Each property starts with its name followed by colon
            if (/^([A-Za-z0-9]{1,}):\s+(.+)$/) {
                $key = $1;
                $val = $2;
                $flag = 0;
            }
            elsif ($key ne '') {
                $flag = 1;
                $val = $_;
            }
            else {
                next;
            }
# Properties with multiple values should be aggregated into arrays
            if (exists($identities->{$name}->{$key}) && !$flag) {
                if (ref($identities->{$name}->{$key}) ne 'ARRAY') {
                    $identities->{$name}->{$key} = [ $identities->{$name}->{$key} ];
                }
                push(@{$identities->{$name}->{$key}}, $val);
            }
            elsif ($flag) {
                $identities->{$name}->{$key} .= "\n" . $val;
            }
            else {
                $identities->{$name}->{$key} = $val;
            }
        }
    }
}
# Get rid of trailing spaces for properties
foreach my $identity (keys(%$identities)) {
    map { $identities->{$identity}->{$_} = remove_trailing_spaces($identities->{$identity}->{$_}); } keys(%{$identities->{$identity}});
}
write_to_log('debug', 'Got ' . scalar(keys(%$identities)) . ' identity(s)');

# Get distribution lists
write_to_log('info', 'Get related distribution lists');
my $distribution_lists = [];
$raw = `@{[ LOCALE ]} @{[ ZMPROV ]} getAccountMembership $account`;
unless ($raw) {
    write_to_log('warn',  'Distribution lists not found');
}
else {
    foreach (split("\n", $raw)) {
        push(@$distribution_lists, $_);
    }
}

write_to_log('debug', 'Account found in ' . scalar(@$distribution_lists) . ' distribution list(s)');

# Get signatures
write_to_log('info', 'Get related signatures');
my $signatures = [];
$raw = `@{[ LOCALE ]} @{[ ZMPROV ]} getSignatures $account`;
unless ($raw) {
    write_to_log('warn',  'Signatures not found');
}
else {
    my $temp = {};
    my $flag = 0;
    my $flag2 = 0;
    my $key = '';
    my $val = '';
    foreach (split("\n", $raw)) {
# Each item in printed list of signatures starts with a comment containing a name of signature
        if (/^# name (.+)$/) {
            if ($flag2) {
                push (@$signatures, $temp);
                $temp = {};
                $flag2 = 0;
            }
        }
        else {
# Each property starts with its name followed by colon
            if (/^([A-Za-z0-9]{1,}):\s+(.+)$/) {
                $key = $1;
                $val = $2;
                $flag = 0;
            }
            elsif ($key ne '') {
                $flag = 1;
                $val = $_;
            }
            else {
                next;
            }
# Properties with multiple values should be aggregated into arrays
            if (exists($temp->{$key}) && !$flag) {
                if (ref($temp->{$key}) ne 'ARRAY') {
                    $temp->{$key} = [ $temp->{$key} ];
                }
                push(@{$temp->{$key}}, $val);
            }
            elsif ($flag) {
                $temp->{$key} .= "\n" . $val;
            }
            else {
                $temp->{$key} = $val;
            }
            $flag2 ||= 1;
        }
    }
    if ($flag2) {
        push (@$signatures, $temp);
    }
}
# Get rid of trailing spaces for properties
foreach my $signature (@$signatures) {
    map { $signature->{$_} = remove_trailing_spaces($signature->{$_}); } keys(%{$signature});
}
write_to_log('debug', 'Got ' . scalar(@$signatures) . ' signature(s)');

# Signatures have unique ids and it's impossible to transfer a signature from
# one account to another, so we have to recreate them and replace all references
# to ids of old signatures with ids of newly created ones
write_to_log('info', 'Search for references to signatures');
foreach my $signature (@$signatures) {
    my $id = $signature->{'zimbraSignatureId'} || '';
    unless ($id) {
        write_to_log('warn', 'Found strange signature without ID!');
        next;
    }

    write_to_log('debug', "Search for references to signature $id");

    foreach (keys (%$properties)) {
        if ($properties->{$_} eq $id) {
            write_to_log('debug', "Found reference to signature $id in account property $_");
            $refs->{'properties'}->{$_} = 1;
        }
    }
    foreach my $key (keys(%$identities)) {
        foreach (keys(%{$identities->{$key}})) {
            if ($identities->{$key}->{$_} eq $id) {
                write_to_log('debug', "Found reference to signature $id in identity $key property $_");
                $refs->{'identities'}->{$key}->{$_} = 1;
            }
        }
    }
}

# Mail aliases should be recreated as well as signatures
write_to_log('info', 'Search for mail aliases');
my $aliases = [];
if (exists($properties->{'zimbraMailAlias'})) {
    $properties->{'zimbraMailAlias'} = [ $properties->{'zimbraMailAlias'} ] if (ref($properties->{'zimbraMailAlias'}) ne 'ARRAY');
    $aliases = $properties->{'zimbraMailAlias'};
    write_to_log('debug', 'Found ' . scalar(@$aliases) . ' alias(es)');
}
else {
    write_to_log('debug', 'Aliases not found');
}

# Export mailbox via REST API if need to
my $export_file_prefix = $options->{'acc'} . '.' . time();
my $export_file = $options->{'temp'} . '/' . $export_file_prefix . '.tgz';
unless ($options->{'skip-emails'}) {
    write_to_log('info', "Export mailbox contents into $export_file");
    unless (open(OUT, '>', $export_file)) {
        write_to_log('error', "Unable to open file with mailbox contents to write: $!");
        exit(10);
    }
    unless (open(IN, '-|', ZMBOX . ' -t 0 -z -m ' . $options->{'acc'} . ' getRestURL //?fmt=tgz')) {
        close(OUT);
        write_to_log('error', "Unable to export mailbox contents: $!");
        exit(11);
    }
    binmode(IN);
    binmode(OUT);
    while (<IN>) { print OUT; }
    close(IN);
    close(OUT);
}
else {
    write_to_log('info', 'Skipping mailbox export according to invocation options');
}

# Main account structure (gather all data in one place)
my $account_structure = { 'properties'         => $properties,
                          'distribution_lists' => $distribution_lists,
                          'signatures'         => $signatures,
                          'identities'         => $identities,
                          'refs'               => $refs,
                          'aliases'            => $aliases };

# Save data structure in a file for future analysys in case of dry run mode
# and/or very verbose (debug) mode
if ($options->{'dry-run'} || $options->{'vverbose'}) {
    write_to_log('info', 'Write export data file '. $options->{'temp'} . '/' . $export_file_prefix . '.dat');
    unless (open(OUT, '>', $options->{'temp'} . '/' . $export_file_prefix . '.dat')) {
        write_to_log('error', "Unable to open export data file during dry run: $!");
        exit(12);
    }
    print OUT Dumper($account_structure);
    close OUT;
    if ($options->{'dry-run'}) {
        write_to_log('info', 'Done in ' . (time - $begin) . ' seconds');
        exit(0);
    }
}

# Here starts actual relocating work...

write_to_log('info', "Rename old account $account to $old_account");
if (system(ZMPROV, 'renameAccount', $account, $old_account)) {
    write_to_log('error', "Unable to rename old account to $old_account: error code $?");
    exit(13);
}

write_to_log('debug', 'Wait for 10 seconds so the changes will be spread through LDAP instances');
sleep(10);

unless ($account_structure->{'properties'}->{'zimbraAccountStatus'} eq 'closed') {
    write_to_log('info', "Close old account $old_account");
    if (system(ZMPROV, 'modifyAccount', $old_account, 'zimbraAccountStatus', 'closed')) {
        write_to_log('warn', "Unable to close old account: error code $?");
    }
}
else {
    write_to_log('debug', "Old account $old_account is already closed, don't need to close it again");
}

write_to_log('info', "Create account $account");
my $dest = $options->{'dest'};
if ($cos_id) {
    if (system(ZMPROV, 'createAccount', $account, TEMP_PWD, 'zimbraMailHost', $dest, 'zimbraCOS', $cos_id)) {
        write_to_log('error', "Unable to create account $account with CoS $cos_id: error code $?");
        exit(14);
    }
}
else {
    if (system(ZMPROV, 'createAccount', $account, TEMP_PWD, 'zimbraMailHost', $dest)) {
        write_to_log('error', "Unable to create account $account with default CoS: error code $?");
        exit(14);
    }
}

write_to_log('debug', 'Wait for 10 seconds so the changes will be spread through LDAP instances');
sleep(10);

unless ($options->{'skip-emails'}) {
    write_to_log('info', "Import mailbox content into the account $account using standard tool");
    if (system(ZMBOX, '-z', '-m', $account, 'postRestURL', '//?fmt=tgz&resolve=reset', $export_file)) {
        write_to_log('error', "Unable to import mailbox contents using standard tool: error code $?");
        if (ADMIN_PASSWORD ne '') {
            write_to_log('info', "Fallback: import mailbox content into the account $account using curl");
            if (system(CURL, '-k', '-H', 'Transfer-Encoding: chunked', '-u', ADMIN_USERNAME . ':' . ADMIN_PASSWORD, '-T', $export_file, '-X', 'POST', IMPORT_SERVER . '/service/home/' . $account . '/?fmt=tgz&resolve=reset')) {
                write_to_log('error', "Unable to import mailbox contents using curl: error code $?");
            }
            else {
                write_to_log('debug', 'Mailbox content successfully imported using curl');
            }
        }
    }
    else {
        write_to_log('debug', 'Mailbox content successfully imported using standard tool');
    }
}
else {
    write_to_log('info', 'Skipping mailbox import according to invocation options');
}

write_to_log('info', 'Restore distribution lists membership for account');
foreach my $list (@{$account_structure->{'distribution_lists'}}) {
    write_to_log('debug', "Restore membership in $list");
    if (system(ZMPROV, 'addDistributionListMember', $list, $account)) {
        write_to_log('warn', "Unable to restore membership in $list distribution list: error code $?");
    }
}

write_to_log('info', 'Restore mail aliases for account');
foreach my $alias (@{$account_structure->{'aliases'}}) {
    write_to_log('debug', "Delete alias $alias for old account $old_account");
    if (system(ZMPROV, 'removeAccountAlias', $old_account, $alias)) {
        write_to_log('warn', "Unable to delete alias $alias for old account $old_account: error code $?");
    }
    else {
        write_to_log('debug', 'Wait for 10 seconds so the changes will be spread through LDAP instances');
        sleep(10);
        write_to_log('debug', "Add alias $alias for $account");
        if (system(ZMPROV, 'addAccountAlias', $account, $alias)) {
            write_to_log('warn', "Unable to add alias $alias for account $account: error code $?");
        }
    }
}

write_to_log('info', 'Restore signatures for account');
foreach my $signature (@{$account_structure->{'signatures'}}) {
    my $name = $signature->{'zimbraSignatureName'};
    write_to_log('debug', "Create signature with name $name");
    my $id = `@{[ LOCALE ]} @{[ ZMPROV ]} createSignature $account "$name"`;
    unless ($id) {
        write_to_log('warn', "Unable to create signature with name $name: error code $?");
        next;
    }
    chomp($id);
    write_to_log('debug', "Signature $name created with id $id and will replace " . $signature->{'zimbraSignatureId'});
    $replacements->{$signature->{'zimbraSignatureId'}} = $id;
    foreach (keys(%$signature)) {
        next if ( ($_ eq 'zimbraSignatureName') || ($_ eq 'zimbraSignatureId') );
        my $value = $signature->{$_};
        if (ref($value) eq 'ARRAY') {
            my $flag = 0;
            foreach my $val (@$value) {
                add_signature_property($account, $id, $_, $val, $flag);
                $flag ||= 1;
            }
        }
        else {
            add_signature_property($account, $id, $_, $value);
        }
    }
}

write_to_log('info', 'Get newly created identities for the account');
my $new_identities = {};
$raw = `@{[ LOCALE ]} @{[ ZMPROV ]} getIdentities $account`;
if ($raw) {
    my $name = '';
    foreach (split("\n", $raw)) {
        if (/^# name (.+)$/) {
            $name = $1;
            if (exists($new_identities->{$name})) {
                write_to_log('warn', "Very strange: duplicate newly created identity $name encountered");
            }
            else {
                $new_identities->{$name} = 1;
                write_to_log('debug', "Found identity $name");
            }
        }
    }
}
write_to_log('debug', 'Got ' . scalar(keys(%$new_identities)) . ' newly created identity(s)');

write_to_log('info', 'Restore identities for account');
foreach my $identity (keys(%{$account_structure->{'identities'}})) {
    write_to_log('debug', "Check whether identity $identity is already created");
    if (exists($new_identities->{$identity})) {
        write_to_log('debug', "Identity with name $identity found, skip creation");
    }
    else {
        write_to_log('debug', "Identity with name $identity not found, create it");
        if (system(ZMPROV, 'createIdentity', $account, $identity)) {
            write_to_log('warn', "Unable to create identity with name $identity: error code $?");
            next;
        }
        write_to_log('debug', "Identity $identity created");
    }

    foreach (keys(%{$account_structure->{'identities'}->{$identity}})) {
        if (exists($service_attributes->{'identities'}->{$_}) && $service_attributes->{'identities'}->{$_}) {
            write_to_log('debug', "Skip identity service property $_");
            next;
        }
        my $value = $account_structure->{'identities'}->{$identity}->{$_};

        if (ref($value) eq 'ARRAY') {
            my $flag = 0;
            foreach my $val (@$value) {
                add_identity_property($account, $identity, $_, $val, $flag);
                $flag ||= 1;
            }
        }
        else {
            if (exists($refs->{'identities'}->{$identity}->{$_})) {
                if (exists($replacements->{$value})) {
                    write_to_log('debug', "Identity $identity has got property $_ value of $value replaced with " . $replacements->{$value});
                    $value = $replacements->{$value};
                }
                else {
                    write_to_log('warn', "Very strange: unable to find replacement for old signature id $value: property $_ of identity $identity");
                    next;
                }
            }
            add_identity_property($account, $identity, $_, $value);
        }
    }
}

write_to_log('info', 'Restore properties for account');
foreach my $property (keys(%{$account_structure->{'properties'}})) {
    if (exists($service_attributes->{'properties'}->{$property}) && $service_attributes->{'properties'}->{$property}) {
        write_to_log('debug', "Skip service property $property");
        next;
    }

    my $value = $account_structure->{'properties'}->{$property};
    if (ref($value) eq 'ARRAY') {
        my $flag = 0;
        foreach my $val (@$value) {
            add_account_property($account, $property, $val, $flag);
            $flag ||= 1;
        }
    }
    else {
        if (exists($refs->{'properties'}->{$property})) {
            if (exists($replacements->{$value})) {
                write_to_log('debug', "Property $property value of $value replaced with " . $replacements->{$value});
                $value = $replacements->{$value};
            }
            else {
                write_to_log('warn', "Very strange: unable to find replacement for old signature id $value: property $property");
                next;
            }
        }
        add_account_property($account, $property, $value);
    }
}

write_to_log('info', 'Try to change "immutable" properties via LDAP');

write_to_log('info', 'Get LDAP password');
my $ldap_password = `@{[ LOCALE ]} @{[ ZMLOCALCONFIG ]} -s zimbra_ldap_password`;
unless ($ldap_password) {
    write_to_log('error', 'Unable to get LDAP password');
    exit(15);
}
$ldap_password =~ s/^zimbra_ldap_password\ =\ //;
chomp($ldap_password);
write_to_log('debug', "Got LDAP password: $ldap_password");

write_to_log('info', "Search for DN for account $account in LDAP");
my $dn = `@{[ LOCALE ]} @{[ LDAPSEARCH ]} -LLL -o ldif-wrap=no -H "@{[ LDAP ]}" -D "@{[ LDAP_BIND_DN ]}" -w "$ldap_password"  -x "(&(objectClass=zimbraAccount)(mail=$account))" | grep "^dn"`;
unless ($dn) {
    write_to_log('error', "Unable to find DN for account $account in LDAP");
    exit(15);
}
chomp($dn);
write_to_log('debug', "Got DN for account $account: $dn");

write_to_log('info', 'Make modifications via LDAP');
foreach my $property (keys(%$special_attributes)) {
    write_to_log('debug', "Proceed with special property $property");
    unless (exists($account_structure->{'properties'}->{$property})) {
        write_to_log('debug', "Special property $property does not exists, skip");
        next;
    }
    my $filename = $options->{'temp'} . '/' . $export_file_prefix . '_' . $property . '.ldif';
    write_to_log('debug', "Compose LDIF file $filename");
    unless (open(OUT, '>', $filename)) {
        write_to_log('error', "Failed to open LDIF file $filename: $!");
        exit(16);
    }
    print OUT "$dn\nchangetype: modify\nreplace: $property\n$property: " . $account_structure->{'properties'}->{$property} . "\n";
    close OUT;
    write_to_log('debug', "Use LDAP to set $property to " . $account_structure->{'properties'}->{$property});
    if (system(LDAPMODIFY, '-f', $filename, '-x', '-H', LDAP, '-D', LDAP_BIND_DN, '-w', $ldap_password)) {
        write_to_log('warn', "Failed to set $property via LDAP: $?");
    }
}

write_to_log('info', 'Done in ' . (time - $begin) . ' seconds');

# Function to log a message
#
# Arguments: (string) log level, (string) message
# Return: none
sub write_to_log {
    my $level = shift;
    my $string = shift;
# Print debug messages only in very verbose mode
    return if ( ($level eq 'debug')
                && !$options->{'vverbose'} );
# Print info messages only in verbose and very verbose modes
    return if ( ($level eq 'info')
                && !$options->{'verbose'}
                && !$options->{'vverbose'} );
# Debug and info messages going to STDOUT, while warnings and errors to STDERR
    my $handler = (($level eq 'debug') || ($level eq 'info')) ? *STDOUT : *STDERR;
    print $handler color( { 'warn'  => 'yellow',
                            'error' => 'red',
                            'info' => 'green',
                            'debug' => 'blue' }->{$level} || 'white') if $color;
    print $handler '[' . uc($level) . ']';
    print $handler color('reset') if $color;
    print $handler ' ' . $string . "\n";
}

# Function to add property for signature using zmprov utility
#
# Arguments: (string) id of account, (string) id of signature,
#            (string) property name, (string) property value,
#            (boolean, optional) flag to add another property with
#            the same name instead of replacing an existing one
# Return: 1 on success, 0 on failure
sub add_signature_property {
    my $account = shift;
    my $signature = shift;
    my $property = shift;
    my $value = shift;
    my $add = shift;
    $add ||= 0;
    write_to_log('debug', "Set $property for signature $signature to $value"
                          . ($add ? ' (add value)' : ''));
    if ( system( ZMPROV, 'modifySignature', $account, $signature,
         ($add ? '+' : '') . $property, $value ) ) {
        write_to_log( 'warn',
                      "Unable to set property $property for signature $signature: error code $?" );
        return 0;
    }
    return 1;
}

# Function to add property for account using zmprov utility
#
# Arguments: (string) id of account, (string) property name,
#            (string) property value, (boolean, optional) flag to add
#            another property with the same name instead of replacing
#            an existing one
# Return: 1 on success, 0 on failure
sub add_account_property {
    my $account = shift;
    my $property = shift;
    my $value = shift;
    my $add = shift;
    $add ||= 0;
    write_to_log('debug', "Set $property for account to $value"
                          . ($add ? ' (add value)' : ''));
    if ( system( ZMPROV, 'modifyAccount', $account,
         ($add ? '+' : '') . $property, $value ) ) {
        write_to_log( 'warn',
                      "Unable to set property $property for account: error code $?" );
        return 0;
    }
    return 1;
}

# Function to add property for identity using zmprov utility
#
# Arguments: (string) id of account, (string) id of identity,
#            (string) property name, (string) property value,
#            (boolean, optional) flag to add another property with
#            the same name instead of replacing an existing one
# Return: 1 on success, 0 on failure
sub add_identity_property {
    my $account = shift;
    my $identity = shift;
    my $property = shift;
    my $value = shift;
    my $add = shift;
    $add ||= 0;
    write_to_log('debug', "Set $property for identity $identity to $value"
                          . ($add ? ' (add value)' : ''));
    if ( system( ZMPROV, 'modifyIdentity', $account, $identity,
                 ($add ? '+' : '') . $property, $value ) ) {
        write_to_log( 'warn',
                      "Unable to set property $property for identity $identity: error code $?" );
        return 0;
    }
    return 1;
}

# Function to compare two arrays
#
# Arguments: (ref) array1, (ref) array2
# Return: 1 if arrays are identical, 0 if they differs
sub compare_arrays {
    my $arr1 = shift;
    my $arr2 = shift;

    return 0 if (scalar(@$arr1) != scalar(@$arr2));

    @$arr1 = sort(@$arr1);
    @$arr2 = sort(@$arr2);

    my $result = 1;
    for (my $i = 0; $i < scalar(@$arr1); $i++) {
        if ($arr1->[$i] ne $arr2->[$i]) {
            $result = 0;
            last;
        }
    }
    return $result;
}

# Function to translate raw output of zmprov commands (namely for account
# properties and CoS settings) into a hash where keys are properties/settings
# names
#
# Argument: (string) raw data
# Return: (ref) hash
sub raw_to_hash {
    my $raw = shift;
    my $hash = {};

# NB.: values could be multilined, also there could be several values for each property
    my $flag = 0;
    my $key = '';
    my $val = '';
    foreach (split("\n", $raw)) {
# Each property starts with its name followed by colon
        if (/^([A-Za-z0-9]{1,}):\s+(.+)$/) {
            $key = $1;
            $val = $2;
            $flag = 0;
        }
        elsif ($key ne '') {
            $flag = 1;
            $val = $_;
        }
        else {
            next;
        }
# Properties with multiple values should be aggregated into arrays
        if (exists($hash->{$key}) && !$flag) {
            if (ref($hash->{$key}) ne 'ARRAY') {
                $hash->{$key} = [ $hash->{$key} ];
            }
            push(@{$hash->{$key}}, $val);
        }
        elsif ($flag) {
            $hash->{$key} .= "\n" . $val;
        }
        else {
            $hash->{$key} = $val;
        }
    }
# Get rid of trailing spaces for properties
    map { $hash->{$_} = remove_trailing_spaces($hash->{$_}); } keys(%$hash);
    return $hash;
}

# Function to get rid of trailing spaces for properties
# (which could be either scalars, or arrays)
#
# Argument: (string|ref) property
# Return: (string|ref)
sub remove_trailing_spaces {
    my $property = shift;
    if (ref($property) eq 'ARRAY') {
        map { $_ = remove_trailing_spaces($_) } @$property;
    }
    else {
        $property =~ s/[\s\n]+$//s;
    }
    return $property;
}
