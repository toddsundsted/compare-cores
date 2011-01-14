package LilyDB;
use strict;

my $DEBUG = 0;

sub new {
    local(*F);
    my ($class, $file, $max_objs) = @_;

    $|=1;
    print "\nLOADING: Reading $file...\n";

    open(F,"<$file") || die "Error opening $file: $!\n";    

    my $self = {};
    bless($self,$class);
    $self->{fh}=\*F;

    $self->{max_objs}=$max_objs;
    $self->read_db();

    return $self;
}

sub read_next_line {
    my ($self) = @_;

    my $fh = $self->{fh};
    my $ret;
    chomp($ret = <$fh>);
#    print "|$ret\n";
    return $ret;
}

sub read_db {
    my ($self)=@_;

    $self->read_header();
    $self->read_users();
    print "LOADING: $self->{nobjs} objects, $self->{nprogs} verbs, $self->{nusers} users";
    print " (" . scalar(@{$self->{users}}) . " read ok)";
    print " - ERROR!" if ($self->{nusers} != scalar(@{$self->{users}}));
    print "\n";
    
    $self->read_objects();

    # build property hashes for each object, doing inheritence of propdefs.
    $self->build_properties();
    
    $self->read_verbs();
    
}

sub read_verbs {
    my ($self) = @_;

    print "LOADING: Reading $self->{nprogs} MOO verb programs...\n";
    for (1..$self->{nprogs}) {
	$self->read_next_verb();
    }    
    print "LOADING: Done reading $self->{nprogs} MOO verb programs...\n";    
}

sub read_next_verb {
    my ($self) = @_;

    my $header = $self->read_next_line();
    my ($oid,$vnum) = ($header =~ /^(\#[\-\d]+):(\d+)/);    
    if (! defined $oid || ! defined $vnum) {
	print "ERROR: \"$header\" does not appear to be a valid verb header\n";
    }
    if (! $self->{$oid}) {
	print "ERROR: verb for non-existent object $oid!\n";
    }

    print "NOTICE: Loading code for $oid:@{$self->{$oid}{verbs}}[$vnum]->{name}\n" if $DEBUG;

    while (1) {
	my $line = $self->read_next_line();
	last if ($line =~ /^\.$/);

	@{$self->{$oid}{verbs}}[$vnum]->{code} .= "$line\n" 
	  if $self->want_obj($oid);
    }

#    print "@{$self->{$oid}{verbs}}[$vnum]->{code}\n";
}


sub build_properties {
    my ($self) = @_;

    print "NOTICE: Building properties:" if $DEBUG;
    my $oid;
    foreach (0..$self->{last_oid}) {
	$oid="\#$_";

	next unless ($self->{$oid});
	next unless ($self->want_obj($oid));	

	print "." if $DEBUG;

	my @pd = ();
	@pd = @{$self->{$oid}{propdefs}} if ($self->{"\#$oid"}{propdefs});
	my @propdefs = ( $self->parent_propdefs($oid) , @pd );

	for (0..$#propdefs) {
	    @{$self->{$oid}{props}}[$_]->{name} = $propdefs[$_];
	}
	
    }
}

sub read_objects {
    my ($self) = @_;

    if ($self->{nobjs} < 1) {
	print "ERROR: Less than 1 object in database?!\n";
    }
    $self->{last_oid} = -1;

    print "LOADING: Reading $self->{nobjs} objects...\n";
    for (1..$self->{nobjs}) {
	$self->read_next_object();
    }
    print "LOADING: Done reading $self->{nobjs} objects...\n";
}

sub read_next_object {
    my ($self)=@_;

    my $oid;
    $oid = $self->read_next_line();
    
    if ($oid !~ /^\#([\-\d]+)(.*)/ || $1 != $self->{last_oid} + 1) {
	print "ERROR: Invalid object id at start of object: \"$oid\"\n";
	return;
    }
    $oid = "\#$1";
    
    $self->{last_oid}++;
    
    if ($2 =~ /recycled/) {
	print "NOTICE: OBJID $oid is recycled.\n";
	return;
    }

    print "NOTICE: Reading object: $oid\n" if $DEBUG;


    foreach (qw(name dummy)) {
	$self->{$oid}{$_}=$self->read_next_line();
    }
    delete $self->{$oid}{dummy};

    foreach (qw(flags owner location contents next parent child sibling)) {
	$self->{$oid}{$_}=$self->read_next_num();
    }

    my $numverbdefs = $self->read_next_num();
    for (1..$numverbdefs) {
	$self->read_next_verbdef($oid);
    }

    my $numpropdefs = $self->read_next_num();
    for (1..$numpropdefs) {
	$self->read_next_propdef($oid);
    }

    my $numprops = $self->read_next_num();
    print "NOTICE: Reading $numprops properties..\n" if $DEBUG;
    for (1..$numprops) {
	$self->read_next_prop($oid);
    }    
}

sub parent_propdefs {
    my ($self,$oid) = @_;
    $oid =~ s/\#//g;

    my $parent = $self->{"\#$oid"}{parent};
    
    return () if ($parent eq $oid);

    my @propdefs = ();
    @propdefs = @{$self->{"\#$oid"}{propdefs}} if ($self->{"\#$oid"}{propdefs});
    return ( @propdefs ,$self->parent_propdefs($parent) );
}

sub read_next_prop {
    my ($self,$oid) = @_;

    print "NOTICE: reading next property from $oid.." if $DEBUG;

    my %prop;
    $prop{value}=$self->read_next_var();
    $prop{owner}=$self->read_next_num();
    $prop{perms}=$self->read_next_num();    

    print " $prop{value}\n" if $DEBUG;

    push @{$self->{$oid}{props}},\%prop if $self->want_obj($oid);
}

sub read_next_num {
    my ($self) = @_;

    my $num = $self->read_next_line();
    if ($num !~ /^[\-\d]+$/) {
	print "ERROR: read_next_num: \"$num\" doesn't look like a number. (called from " . (caller(1))[3] . "\n";
    }

    return $num;
}

sub read_next_var {
    my ($self) = @_;

    my $type = $self->read_next_num();
    my $val;

    if ($type == 5 || $type == 6) { return undef; }

    if ($type == 4) { # lists
	my $nelements = $self->read_next_num();
	my @list;
	for (1..$nelements) {
	    push @list, $self->read_next_var();
	}
	$val = "{" . (join ', ', @list) . "}";
    } elsif ($type == 10) { # hashes
	my $nelements = $self->read_next_num();
	my @hash;
	for (1..$nelements) {
	    push @hash, $self->read_next_var() . " -> " . $self->read_next_var();
	}
	$val = "[" . (join ', ', @hash) . "]";
    } else {
	$val = $self->read_next_line();
    }

    return $val;
}


sub read_next_verbdef {
    my ($self,$oid) = @_;

    my %verbdef;
    $verbdef{name} = $self->read_next_line();
    print "NOTICE: Reading verbdef for $oid:$verbdef{name}\n" if $DEBUG;
    foreach (qw(owner perms prep)) {
	$verbdef{$_} = $self->read_next_num();
    }

    $verbdef{next} = 0;
    $verbdef{program} = 0;

    push @{$self->{$oid}{verbs}}, \%verbdef if $self->want_obj($oid);
}


sub read_next_propdef {
    my ($self,$oid) = @_;

    my $name = $self->read_next_line();
    print "NOTICE: Reading  propdef for $oid.$name\n" if $DEBUG;
    push @{$self->{$oid}{propdefs}},$name if $self->want_obj($oid);
}


sub read_users {
    my ($self)=@_;

    if ($self->{nusers} < 1) {
	print "ERROR: Less than 1 user in database?!\n";
    }
    for (1..$self->{nusers}) {
	my $num = $self->read_next_line();
	push @{$self->{users}},$num;
    }
}


sub read_header {
    my ($self)=@_;

    $self->{version} = $self->read_next_line();
    
    unless ($self->{version} =~ /LambdaMOO Database, Format Version [0-9]+/) {
	print "ERROR: Unexpected DB Version: $self->{version}\n";
    }

    foreach (qw(nobjs nprogs dummy nusers)) {
	$self->{$_}=$self->read_next_num();
    }
    delete $self->{dummy};
}

sub want_obj {
    my ($self,$oid) = @_;

    $oid =~ s/^\#//g;
    
    if ($self->{max_objs} && $oid > $self->{max_objs}) {
	return 0;
    } else {
	return 1;
    }
}

1;
